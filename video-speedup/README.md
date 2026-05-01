# 🎬 Video Speed + Compress Script (PowerShell + FFmpeg)

A simple PowerShell script to speed up videos and reduce file size in one step.

---

## ✨ Features

- File picker (no need to type paths)
- Adjustable playback speed (default: 1.3x)
- Quality presets:
  - High (better quality, larger size)
  - Balanced (recommended)
  - Small (lower quality, smaller size)
- Live progress feedback in console
- Supports multiple files

---

## 📦 Requirements

This script depends on **FFmpeg**.

### Check if installed:
```
ffmpeg --version
```

### Install on Windows 11:
```
winget install ffmpeg
```

> `ffprobe` is also required and is included with FFmpeg.

---

## 🚀 Usage

Run the script:

```
pwsh .\speedup-video.ps1
```

### Steps:
1. Select one or more video files
2. Enter desired speed (press Enter for default 1.3)
3. Choose output quality
4. Wait for processing to complete

---

## 📁 Output

Processed files are saved next to the original file:

```
filename-speed1.3.mp4
```

---

## 💡 Example

- Input: 50MB screen recording  
- Output: ~17MB  
- Speed: 1.3x  
- Quality: Balanced  

---

## 🎯 Why this exists

Screen recordings (e.g. using Snagit) are often:
- slightly longer than needed
- larger than necessary for sharing
- slower-paced (especially when explaining step-by-step)

This script helps speed up delivery and reduce file size at the same time.
