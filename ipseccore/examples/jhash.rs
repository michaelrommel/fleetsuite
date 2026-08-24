//! On-host jhash / owner cross-check for the LVS ring (Increment 6g phase 2b).
//!
//! Usage:
//!   cargo run -p ipseccore --example jhash -- <customer_ip> [<node0> <node1> ...]
//!
//! Prints the kernel-exact jhash of <customer_ip> (matching nftables
//! `jhash ip saddr ... seed 0xa5a5a5a5`), the value the throwaway nft probe
//! shows in MARK (= hash - 1, reciprocal_scale over modulus 2^32-1), and -- if
//! the ring node IPs are given in map order -- the reciprocal_scale index and
//! the owning node that `jhash ip saddr mod N seed 0xa5a5a5a5 map {...}` selects.
//!
//! Examples:
//!   jhash 62.238.96.148
//!   jhash 62.238.96.148 172.16.49.73 172.16.50.8

use std::net::Ipv4Addr;

fn main() {
	let args: Vec<String> = std::env::args().skip(1).collect();
	if args.is_empty() {
		eprintln!("usage: jhash <customer_ip> [<node0> <node1> ...]");
		std::process::exit(2);
	}
	let ip: Ipv4Addr = match args[0].parse() {
		Ok(v)  => v,
		Err(e) => { eprintln!("bad IP '{}': {e}", args[0]); std::process::exit(2); }
	};

	let seed = ipseccore::JHASH_SEED_U32;
	let h    = ipseccore::jhash_ipv4(ip, seed);
	// reciprocal_scale(h, 2^32-1) == h-1 (for h>=1) -- what the nft probe prints.
	let mark = ((h as u64 * 0xFFFF_FFFFu64) >> 32) as u32;

	println!("ip           : {ip}");
	println!("seed         : {} (0x{seed:08X})", ipseccore::JHASH_SEED);
	println!("jhash        : {h} (0x{h:08X})");
	println!("nft MARK     : 0x{mark:08X}   (probe: jhash daddr mod 4294967295; = jhash - 1)");

	let nodes: Vec<String> = args[1..].to_vec();
	if nodes.is_empty() {
		print!("index by N   :");
		for n in 1..=8usize {
			print!(" N{n}={}", ipseccore::owner_index(ip, n));
		}
		println!();
		return;
	}
	let idx   = ipseccore::owner_index(ip, nodes.len());
	let owner = ipseccore::owner_of(ip, &nodes).unwrap_or("?");
	println!("ring (N={})   : {nodes:?}", nodes.len());
	println!("index        : {idx}   (reciprocal_scale, NOT modulo)");
	println!("owner        : {owner}");
}
