//! wtx chat room: every message a client sends is published to every client,
//! prefixed with the sender's name.
//!
//! The workload of Bun's `bench/websocket-server` and of `src/chatserver.nim`:
//! 32 clients, one round = 51,200 publishes / 1,638,400 frame deliveries.
//!
//! wtx has no room abstraction, so the fan-out is the one a Rust application
//! writes by hand: every connection is split into non-locking halves
//! (`into_split`), the reader publishes into a list of per-connection queues
//! (one payload copy per publish, as many queue pushes as there are members),
//! and each connection's own writer task drains its queue into its socket.

use std::{
    error::Error as _,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use tokio::{
    net::{TcpListener, TcpStream},
    sync::mpsc::{self, UnboundedSender},
};
use wtx::{
    collections::Vector,
    misc::Lease as _,
    rng::{ChaCha20, CryptoSeedableRng},
    tls::{TlsAcceptor, TlsConfig},
    web_socket::{
        Frame, OpCode, WebSocketAcceptor, WebSocketPayloadOrigin,
    },
};

/// A published line: the frame's kind and its payload, shared by every member
/// of the room instead of being copied per member.
type Line = (OpCode, Arc<[u8]>);

struct Hub {
    writers: Mutex<Vec<UnboundedSender<Line>>>,
    joined: AtomicUsize,
    expected: usize,
}

impl Hub {
    /// One line to every member. A member whose queue is closed (the peer
    /// went away) is dropped here — the same place the nimony `Room` learns
    /// that a subscriber is gone.
    fn publish(&self, op_code: OpCode, payload: Arc<[u8]>) {
        let mut writers = self.writers.lock().expect("room lock");
        writers.retain(|writer| writer.send((op_code, payload.clone())).is_ok());
    }

    fn join(&self, writer: UnboundedSender<Line>) {
        self.writers.lock().expect("room lock").push(writer);
    }
}

#[tokio::main]
async fn main() -> wtx::Result<()> {
    let port = wtx_server::env_u16("PORT", 4001);
    let hub = Arc::new(Hub {
        writers: Mutex::new(Vec::new()),
        joined: AtomicUsize::new(0),
        expected: wtx_server::env_usize("CLIENTS_COUNT", 32),
    });
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    println!("listening on port {port}");
    loop {
        let (stream, _peer) = listener.accept().await?;
        let hub = hub.clone();
        tokio::spawn(async move {
            if let Err(err) = chat(stream, &hub).await {
                eprintln!("wtx chat: {err}");
                if let Some(source) = err.source() {
                    eprintln!("  caused by: {source}");
                }
            }
        });
    }
}

async fn chat(stream: TcpStream, hub: &Arc<Hub>) -> wtx::Result<()> {
    stream.set_nodelay(true)?;
    // `?name=Alice0` off the handshake: the same string the nimony and Bun
    // servers prefix every published line with.
    let mut name = String::new();
    let rng = ChaCha20::from_getrandom()?;
    let ws = WebSocketAcceptor::default()
        .set_req(|req| {
            if let Some(path) = req.path {
                name.push_str(&wtx_server::name_from_path(path));
            }
            wtx::Result::Ok(true)
        })
        .accept(TlsAcceptor::new(TlsConfig::plaintext(), rng, stream))
        .await?;

    // The non-locking halves: the reader runs here, the writer in its own
    // task, and a publish only has to reach the writer's queue.
    let (_bridge, mut reader, mut writer) = ws.into_split()?;
    let (tx, mut rx) = mpsc::unbounded_channel::<Line>();
    hub.join(tx.clone());

    // What the Bun server does once the room is full: tell everybody, so the
    // clients stop waiting for their first message and start sending.
    if hub.joined.fetch_add(1, Ordering::Relaxed) + 1 == hub.expected {
        let hub = hub.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            hub.publish(OpCode::Text, Arc::from(&b"ready"[..]));
        });
    }

    let writer_task = tokio::spawn(async move {
        // One buffer per connection, reused: the payload is copied out of the
        // shared line into the frame the socket writes, which is the per-member
        // append the nimony `Room` does.
        let mut payload = Vector::new();
        while let Some((op_code, line)) = rx.recv().await {
            payload.clear();
            payload.extend_from_copyable_slice(&line)?;
            let mut frame = Frame::new_fin(op_code, &mut payload)?;
            writer.write_frame(&mut frame).await?;
        }
        Ok::<(), wtx::Error>(())
    });

    let mut buffer = Vector::new();
    let mut line = Vec::new();
    loop {
        let origin = WebSocketPayloadOrigin::Adaptive;
        let frame = reader.read_frame(&mut buffer, origin).await?;
        match frame.op_code() {
            OpCode::Text | OpCode::Binary => {
                line.clear();
                line.extend_from_slice(name.as_bytes());
                line.extend_from_slice(b": ");
                line.extend_from_slice(frame.payload().lease());
                hub.publish(frame.op_code(), Arc::from(line.as_slice()));
            }
            OpCode::Close => break,
            _ => {}
        }
    }

    // Dropping our sender is what ends the writer task: it drains what is
    // already queued and closes the socket.
    drop(tx);
    let _ = writer_task.await;
    Ok(())
}
