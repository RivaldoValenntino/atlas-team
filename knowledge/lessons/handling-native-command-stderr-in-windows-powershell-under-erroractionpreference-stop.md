---
id: handling-native-command-stderr-in-windows-powershell-under-erroractionpreference-stop
title: "Handling Native Command Stderr in Windows PowerShell under ErrorActionPreference Stop"
category: lessons
tags: ["powershell", "git", "error-handling", "windows", "acle"]
created_at: 2026-11-21T13:09:15+07:00
updated_at: 2026-11-21T13:09:15+07:00
author: ATLAS Continuous Learning Engine
verified: true
scope: universal
---

# Handling Native Command Stderr in Windows PowerShell under ErrorActionPreference Stop

## Root Cause
Saat memanggil executable native (seperti git fetch atau git pull) di Windows PowerShell, output kemajuan (progress/informasi) ditulis ke stream stderr. Jika ErrorActionPreference disetel ke Stop dan stderr diarahkan menggunakan 2>&1, PowerShell secara default menganggap pesan tersebut sebagai terminating error (RemoteException) meskipun program keluar dengan exit code 0.

## Solusi Terverifikasi
1. Gunakan ErrorActionPreference = 'Continue' di sekitar pemanggilan native CLI.
2. Nonaktifkan PSNativeCommandUseErrorActionPreference jika tersedia di PowerShell 7+.
3. Periksa status keberhasilan secara eksplisit menggunakan LASTEXITCODE -ne 0 alih-alih mengandalkan tangkapan stream 2>&1.