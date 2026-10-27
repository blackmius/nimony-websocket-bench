//! wtx echo server: every message goes back to the connection that sent it.
//!
//! The counterpart of `src/echoserver.nim` and `src/echo-server.bun.js`, driven
//! by the same client (`src/bench-client.mjs` with `READY=0` and
//! `TOTAL_CLIENTS=1`, so each client counts only its own echoes).
//!
//! wtx is not a framework: this is its low-level `WebSocketAcceptor` over a
//! plaintext `TlsAcceptor`, one tokio task per connection, which is what the
//! crate's own `web-socket-server` example does.

use std::error::Error as _;

use tokio::net::{TcpListener, TcpStream};
use wtx::{
    collections::Vector,
    rng::{ChaCha20, CryptoSeedableRng},
    tls::{TlsAcceptor, TlsConfig},
    web_socket::{OpCode, WebSocketAcceptor, WebSocketPayloadOrigin},
};

#[tokio::main]
async fn main() -> wtx::Result<()> {
    let port = wtx_server::env_u16("PORT", 4001);
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    println!("listening on port {port}");
    loop {
        let (stream, _peer) = listener.accept().await?;
        tokio::spawn(async {
            if let Err(err) = echo(stream).await {
                // A client that goes away mid-frame is not an event worth a
                // backtrace; the same reason the nimony server swallows its
                // `ErrorCode`s.
                eprintln!("wtx echo: {err}");
                if let Some(source) = err.source() {
                    eprintln!("  caused by: {source}");
                }
            }
        });
    }
}

async fn echo(stream: TcpStream) -> wtx::Result<()> {
    // The same Nagle decision the other servers make: a WebSocket reply is
    // small and the client waits for it before sending the next message.
    stream.set_nodelay(true)?;
    let rng = ChaCha20::from_getrandom()?;
    let mut ws = WebSocketAcceptor::default()
        .accept(TlsAcceptor::new(TlsConfig::plaintext(), rng, stream))
        .await?;
    // `msg` lives outside the loop, like the nimony server's: the reader fills
    // the caller's buffer in place, so a message costs no allocation once the
    // buffer has grown to size.
    let mut buffer = Vector::new();
    let (mut common, mut reader, mut writer) = ws.split_mut();
    loop {
        let origin = WebSocketPayloadOrigin::Adaptive;
        let mut frame = reader.read_frame(&mut buffer, &mut common, origin).await?;
        match frame.op_code() {
            OpCode::Text | OpCode::Binary => writer.write_frame(&mut common, &mut frame).await?,
            OpCode::Close => break,
            _ => {}
        }
    }
    Ok(())
}
