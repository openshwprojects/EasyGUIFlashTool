# Testing

## NiceMCU BK7238 - Flash Read Backup

The following command works well for testing on the NiceMCU BK7238 board. It performs a full flash read and saves the output to a backup file. The tool handles autoreset via RTS/DTR, so no manual reset is needed.

```
EasyGUIFlashTool.exe --chip BK7238 fread --out bk7238_backup.bin
```

- **Chip:** BK7238
- **Operation:** Full flash read (`fread`)
- **Output:** `bk7238_backup.bin`
- **Auto-reset:** Yes, via RTS/DTR
