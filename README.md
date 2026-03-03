# broadcaster

## Log

```
journalctl -u broadcaster.service -f
journalctl -u dns-update.service -f
```

## Status

```
systemctl status broadcaster
systemctl list-timers | grep dns-update
```
