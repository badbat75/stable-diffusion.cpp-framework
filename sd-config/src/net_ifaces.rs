// Network interface enumeration for the "Bind to" combo in the Server tab.
//
// On Windows, `if-addrs` walks GetAdaptersAddresses and returns the friendly
// adapter name (e.g. "Ethernet", "Wi-Fi") alongside each IPv4/IPv6 address
// and netmask. We surface IPv4 only — sd-server's --listen-ip is a single
// address, and IPv6 binding is rare enough not to warrant cluttering the
// dropdown. Loopback (127/8) and APIPA link-local (169.254/16) are filtered
// out because they're not useful bind targets ("localhost" already covers
// loopback; link-local means the adapter has no real connectivity).

use std::net::Ipv4Addr;

#[derive(Debug, Clone)]
pub struct BindOption {
    /// What the dropdown shows.
    pub label: String,
    /// What gets written to server.ini's Hostname key.
    pub value: String,
}

/// The fixed entries at the top of the list, plus every usable IPv4 interface.
pub fn list_options() -> Vec<BindOption> {
    // NOTE: gui.rs::populate_bind_options inserts a synthetic "no longer
    // present" row at index 2 (right after these two fixed entries) when
    // the saved hostname isn't present in the live interface list. Keep
    // these two entries first or update both files together.
    let mut out = vec![
        BindOption {
            label: "localhost (only this machine)".into(),
            value: "localhost".into(),
        },
        BindOption {
            label: "0.0.0.0 (all interfaces, LAN-reachable)".into(),
            value: "0.0.0.0".into(),
        },
    ];

    let mut ifaces = match if_addrs::get_if_addrs() {
        Ok(v) => v,
        Err(_) => return out,
    };

    // Stable order: by adapter name, then by IP within an adapter.
    ifaces.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| a.ip().to_string().cmp(&b.ip().to_string()))
    });

    for iface in ifaces {
        let if_addrs::IfAddr::V4(v4) = iface.addr else {
            continue;
        };
        if v4.ip.is_loopback() || v4.ip.is_link_local() {
            continue;
        }
        let prefix = netmask_to_prefix(v4.netmask);
        let network = network_of(v4.ip, v4.netmask);
        let label = format!(
            "{ip} ({name} — {net}/{prefix})",
            ip = v4.ip,
            name = iface.name,
            net = network,
            prefix = prefix,
        );
        out.push(BindOption {
            label,
            value: v4.ip.to_string(),
        });
    }

    out
}

fn netmask_to_prefix(mask: Ipv4Addr) -> u32 {
    mask.octets().iter().map(|b| b.count_ones()).sum()
}

fn network_of(ip: Ipv4Addr, mask: Ipv4Addr) -> Ipv4Addr {
    let ip_u = u32::from(ip);
    let mk_u = u32::from(mask);
    Ipv4Addr::from(ip_u & mk_u)
}
