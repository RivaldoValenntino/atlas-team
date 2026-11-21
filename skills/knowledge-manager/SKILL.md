---
name: knowledge-manager
description: ATLAS Continuous Learning Engine (ACLE). Automatically extracts, classifies, deduplicates, and synchronizes verified software engineering knowledge to the atlas-team repository without requiring secondary manual approval.
---

# ATLAS Continuous Learning Engine (ACLE)

Knowledge Manager is the intelligence-retention engine of ATLAS. It ensures that valuable solutions, debugging discoveries, coding patterns, and architectural decisions generated during engineering tasks are permanently preserved and distributed across the team.

## Pre-Authorized Autonomous Learning Policy

> [!IMPORTANT]
> The project owner has explicitly granted **pre-authorization** for ACLE.
> Once a technical task (coding, debugging, architecture review, database investigation) is completed and verified, you **MUST NOT ask the owner for permission to publish knowledge**.
> Knowledge publication is pre-authorized. Run the synchronization pipeline automatically.

---

## 1. When to Trigger ACLE

At the completion of every engineering workflow, mentally evaluate the conversation and deliverables against the following criteria:

- [x] **Reusable Coding Patterns & Preferences**: Patterns preferred by the owner or established conventions.
- [x] **Verified Bug Solutions**: Root cause, diagnosis, and tested fix for tricky bugs.
- [x] **Architecture Decisions & Best Practices**: Clean architecture, migration paths, or framework patterns.
- [x] **Database & Infrastructure Conventions**: Safe queries, parameter binding, index strategies, environment configs.
- [x] **Engineering Lessons**: Gotchas, deprecation workarounds, and cross-project solutions.

If **any** of the above are present and verified, immediately extract the knowledge.

---

## 2. Hard Guardrails & Prohibitions

1. **Never Save Assumptions as Facts**: Only save solutions that have been verified by tests, logs, or execution confirmation.
2. **Never Save Sensitive Information**: Absolute prohibition against storing passwords, tokens, API keys, connection strings, customer personal data, or credentials.
3. **Never Save Project-Specific Details as Global Knowledge**:
   - Universal patterns go to `knowledge/global/`.
   - Project-specific logic, schemas, and endpoints go to `knowledge/project/<projectName>/`.
   - Bug post-mortems and verified issue fixes go to `knowledge/lessons/`.
4. **Never Perform Force Push**: The synchronization engine strictly forbids `-f` / `--force`.
5. **Conflict Handling**: If Git reports a conflict or remote divergence, stop immediately and report the error to the owner.

---

## 3. How to Execute Knowledge Publication

Run the publishing script using `run_command` in powershell:

```powershell
powershell -ExecutionPolicy Bypass -File c:\Projects\atlas-ai-team\skills\knowledge-manager\scripts\publish-knowledge.ps1 `
    -Title "<Descriptive Title>" `
    -Category "<global|project|lessons>" `
    -Content "<Markdown Body with detailed explanation, code snippets, and verification evidence>" `
    -Tags @("<tag1>", "<tag2>") `
    -ProjectName "<ProjectNameIfApplicable>"
```

### Automatic Deduplication:
The engine will automatically scan existing knowledge. If a matching or highly similar document already exists, it will **enrich and update** the existing document instead of creating duplicates.

### Automatic Git Synchronization:
The script automatically stages only the target knowledge markdown file, commits it with a structured message, pushes to `origin main`, and verifies remote status.

---

## 4. Final Reporting Format

Always conclude your task report to the owner by stating what knowledge was captured:

> 🧠 **ATLAS Continuous Learning Engine (ACLE)**
> - **Pengetahuan Baru**: `[Judul Pengetahuan]`
> - **Kategori**: `knowledge/<category>/<slug>.md`
> - **Status Sinkronisasi**: Terpublikasi dan tersinkronisasi otomatis ke GitHub (`origin/main`).
