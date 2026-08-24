# Open Points

## Portal
- investigate group admin grants, listed as device grants

## AeroFTP Loadbalancer
- routing of EC2 requests are destined to external IPs not VPCEndpoints:
13:44:10.378974 IP ip-172-16-54-12.eu-west-2.compute.internal.15738 > ec2-13-43-47-198.eu-west-2.compute.amazonaws.com.443: Flags [S], seq 1152658388, win 35844, options [mss 8961,sackOK,TS val 3481388929 ecr 0,nop,wscale 9], length 0
	0x0000:  4500 003c 5db6 4000 4006 bdf8 ac10 360c  E..<].@.@.....6.
	0x0010:  0d2b 2fc6 3d7a 01bb 44b4 2bd4 0000 0000  .+/.=z..D.+.....
	0x0020:  a002 8c04 1f3c 0000 0204 2301 0402 080a  .....<....#.....
	0x0030:  cf81 c781 0000 0000 0103 0309            ............
13:44:11.402979 IP ip-172-16-54-12.eu-west-2.compute.internal.15738 > ec2-13-43-47-198.eu-west-2.compute.amazonaws.com.443: Flags [S], seq 1152658388, win 35844, options [mss 8961,sackOK,TS val 3481389953 ecr 0,nop,wscale 9], length 0
	0x0000:  4500 003c 5db7 4000 4006 bdf7 ac10 360c  E..<].@.@.....6.
	0x0010:  0d2b 2fc6 3d7a 01bb 44b4 2bd4 0000 0000  .+/.=z..D.+.....
	0x0020:  a002 8c04 1f3c 0000 0204 2301 0402 080a  .....<....#.....
	0x0030:  cf81 cb81 0000 0000 0103 0309            ............
13:44:12.426999 IP ip-172-16-54-12.eu-west-2.compute.internal.15738 > ec2-13-43-47-198.eu-west-2.compute.amazonaws.com.443: Flags [S], seq 1152658388, win 35844, options [mss 8961,sackOK,TS val 3481390977 ecr 0,nop,wscale 9], length 0
	0x0000:  4500 003c 5db8 4000 4006 bdf6 ac10 360c  E..<].@.@.....6.
	0x0010:  0d2b 2fc6 3d7a 01bb 44b4 2bd4 0000 0000  .+/.=z..D.+.....
	0x0020:  a002 8c04 1f3c 0000 0204 2301 0402 080a  .....<....#.....
	0x0030:  cf81 cf81 0000 0000 0103 0309            ............

- also on aeroscale: why are there so many WRITES to valkey? There seem to be constant updates to the slot system. Should not be needed.

# vpp.rs
   549 // TODO(backend-mode): if the VPP-VRF ('backend') path is ever used, it needs its
   550 // own port splits on vpp-outer scoped by real_ip (the post-SNAT dst), not the
   551 // old global-by-port rules.

Also is the multiplexed connection that also exists to VICI immune to Valkey outages? Does it have an
automatic reconnect method?

Is it possible to hit limits of command line length when constructing commands like this:

 +173       let elems = desired.iter().cloned().collect::<Vec<_>>().join(", ");
 +174       batch.push_str(&format!("add element ip {NFT_TABLE} {NFT_ACTIVE_SET} {{ {elems} }}\n"));


