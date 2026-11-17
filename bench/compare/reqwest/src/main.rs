// The reqwest side of the client comparison.
//
//     reqwest-bench <url> <requests> <workers> <h1|h2>
//
// One blocking `Client` shared by the workers, so the workers share the
// connection pool. The body is read to the end and dropped, matching the
// other two clients.

use std::env;
use std::sync::Arc;
use std::time::Instant;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() != 4 {
        eprintln!("usage: reqwest-bench <url> <requests> <workers> <h1|h2>");
        std::process::exit(2);
    }
    let url = args[0].clone();
    let total: usize = args[1].parse()?;
    let workers: usize = args[2].parse()?;
    let h2 = match args[3].as_str() {
        "h2" => true,
        "h1" => false,
        _ => {
            eprintln!("mode must be h1 or h2");
            std::process::exit(2);
        }
    };

    let mut builder = reqwest::blocking::Client::builder()
        .danger_accept_invalid_certs(true)
        .tcp_nodelay(true)
        .pool_max_idle_per_host(workers);
    builder = if h2 {
        builder.http2_prior_knowledge()
    } else {
        builder.http1_only()
    };
    let client = Arc::new(builder.build()?);

    let per = total / workers;
    let start = Instant::now();
    std::thread::scope(|scope| {
        for _ in 0..workers {
            let client = Arc::clone(&client);
            let url = url.clone();
            scope.spawn(move || {
                for _ in 0..per {
                    let response = client.get(&url).send().expect("send");
                    let _ = response.bytes().expect("body");
                }
            });
        }
    });
    println!("reqwest {} {}", per * workers, start.elapsed().as_nanos());
    Ok(())
}
