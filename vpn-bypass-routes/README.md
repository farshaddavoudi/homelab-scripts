# VPN Bypass Routes (Windows)

`vpn-bypass-routes.ps1` is an interactive Windows route manager for the "some IPs must bypass the VPN" case.

It keeps the IP list in a plain text file, detects the current non-VPN gateway automatically, and rewrites the persistent host routes to that gateway when you switch Wi-Fi or LAN networks.

It also supports storing domain names and notes next to each IP so the menu can show which website or service each bypass route belongs to.

## Folder contents

- `vpn-bypass-routes.ps1`: main interactive script.
- `run-vpn-bypass-routes.cmd`: double-click launcher.
- `bypass-routes.txt`: managed list of IPv4 addresses plus optional domain names and notes.
- `dns-resolvers.txt`: public DNS resolver IPs used for domain lookups when VPN DNS is broken.

## Why this exists

When a VPN client pushes a full-tunnel config, Windows sends most traffic through the VPN adapter.

If you manually add persistent host routes like:

```powershell
route -p add 185.143.233.235 mask 255.255.255.255 192.168.10.1 metric 1
```

the rule breaks as soon as your normal network gateway changes from `192.168.10.1` to something else such as `192.168.0.1`.

This script solves that by:

1. Storing the bypass IPs in one file.
2. Detecting the current non-VPN default gateway.
3. Rebuilding the managed persistent routes for that gateway.

## Requirements

- Windows 11
- PowerShell
- Administrator rights when applying or removing routes

You can still open the script and inspect the lists without admin rights. The script only asks for elevation when you choose an action that changes Windows routes.

## Usage

Recommended:

1. Open the `vpn-bypass-routes` folder.
2. Double-click `run-vpn-bypass-routes.cmd`.
3. Choose an option from the menu.

You can also run the PowerShell file directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\vpn-bypass-routes.ps1
```

## Menu options

The script shows the current detected non-VPN gateway at the top of the menu, plus:

- managed entry count from `bypass-routes.txt`
- how many managed entries already have domain names
- matching managed persistent routes in Windows
- other persistent `/32` routes that are not yet in the managed list

Available actions:

1. Show the managed IP list with domains and notes.
2. Apply or refresh the managed routes to the current detected gateway.
3. Remove the managed routes from Windows.
4. Show the matching managed persistent routes from Windows together with stored domains and notes.
5. Add new IPs or update domains/website metadata for existing IPs.
6. Remove IPs from the managed list.
7. Show other persistent `/32` routes not in the managed list.
8. Import those other persistent `/32` routes into the managed list.
9. Resolve a domain name and add its current IPv4 addresses to the managed list.
10. Refresh all saved domain-based entries from current DNS results.
11. Open `bypass-routes.txt` in Notepad.
12. Print the equivalent OpenVPN lines using `net_gateway`.

## Managed list file

`bypass-routes.txt` accepts these formats:

```text
185.143.233.235
185.166.104.30 | example.com
94.182.111.251 | example.com, www.example.com | main website
```

Blank lines and lines that start with `#` are ignored.

Notes:

- The first field is always the IPv4 address.
- The second field is optional and is intended for domain names or website labels.
- The third field is optional and can hold any note you want.
- The script remains backward-compatible with old files that contain only raw IPs.

## OpenVPN note

If your OpenVPN profile allows client-side route lines, the script can print lines like:

```text
route 185.143.233.235 255.255.255.255 net_gateway    # example.com
```

That is often cleaner than hardcoding the current Wi-Fi gateway into the `.ovpn` profile.

## DNS and domain workflow

There are now two good ways to manage website names:

1. Add the IPs manually and attach domains/notes with menu option `5`.
2. Start from a domain name with menu option `9`, let the script resolve the current A-record IPs, then save those IPs together with the domain name.

Important:

- Windows routes still work at the IP layer, not the domain layer.
- If a website changes IPs later, the saved route entries can become stale.
- Menu option `9` is useful when you want to refresh the IP list from the current DNS result.
- Menu option `9` tries the public resolvers from `dns-resolvers.txt` before it falls back to the current system DNS path.
- Menu option `10` re-resolves every saved domain in the list, shows an old-IP/new-IP preview, and then rewrites the domain-based entries if you confirm.
- If a saved domain cannot be resolved during option `10`, the script keeps its previous IPs instead of dropping the entry.

## Public resolver file

`dns-resolvers.txt` contains public DNS server IPv4 addresses such as:

```text
1.1.1.1
8.8.8.8
9.9.9.9
208.67.222.222
```

This is useful when the VPN-connected DNS path cannot resolve the domain you want to bypass.

## Safety notes

- The script only manages the IPs that exist in `bypass-routes.txt`.
- It does not silently remove other persistent routes.
- For unknown old host routes, use menu options `7` and `8` to review and import them first.
