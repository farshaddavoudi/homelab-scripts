# clone-all-ado-repos.ps1

A simple and practical PowerShell script to clone **all projects and all repositories** from an on-premises Azure DevOps Server instance.

---

## ✨ Features

- 🔍 Fetches all projects automatically  
- 📦 Clones all repositories inside each project  
- 📁 Clean folder structure (Project → Repo)  
- ⏭️ Skips already cloned repositories  
- 🔐 Uses Personal Access Token (PAT) authentication  
- 🧰 Works in restricted / on-prem environments  
- 🪞 Optional mirror mode (full backup)

---

## 📂 Output Structure

```
C:\Backup\ADO\
 ├── ProjectA\
 │    ├── Repo1\
 │    └── Repo2\
 ├── ProjectB\
 │    └── Repo1\
```

---

## 🚀 Usage

### 1. Generate a PAT

In Azure DevOps Server:
- Go to User Settings → Personal Access Tokens  
- Scope: **Code (Read)**  

---

### 2. Run Script

```powershell
powershell -ExecutionPolicy Bypass -File .\Clone-All-AdoRepos.ps1 `
  -CollectionUrl "https://your-server/CollectionName" `
  -PAT "your_token_here" `
  -OutputFolder "D:\Backup\ADO"
```

---

### 3. Optional: Mirror Mode (Full Backup)

```powershell
- Mirror clones include all refs (branches, tags, etc.)
```

```powershell
.\clone-all-ado-repos.ps1 -Mirror
```

---

## ⚙️ Parameters

| Parameter         | Description |
|------------------|------------|
| `CollectionUrl`  | Azure DevOps collection URL |
| `PAT`            | Personal Access Token |
| `OutputFolder`   | Target folder for cloning |
| `Mirror`         | Clone as mirror (full backup) |

---

## ⚠️ Common Issues

### TLS / Certificate Errors
If you see connection issues, ensure TLS 1.2 is enabled.

---

### Invalid URL
Make sure your URL matches one of these:

```
https://server/tfs/CollectionName
https://server/CollectionName
```

---

### Authentication Failed
- Check PAT permissions  
- Ensure token is not expired  

---

## 🧠 Notes

- Designed for **on-prem Azure DevOps Server**
- No dependency on Azure CLI
- Safe to re-run (skips existing repos)

---

## 🔮 Possible Improvements

- 🔁 Incremental sync (git pull)
- ⚡ Parallel cloning
- 📜 Logging for CI/CD
- 🧹 Skip archived projects

---

## 👨‍💻 Author

Part of personal homelab / DevOps tooling.
