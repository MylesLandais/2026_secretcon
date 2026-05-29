#!/usr/bin/env python3
"""SecretCon repo audit harness — walks files and emits JSON + Markdown reports."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
REPORTS_DIR = REPO_ROOT / "audit" / "reports"

SKIP_DIRS = {
    ".git",
    ".direnv",
    "node_modules",
    "__pycache__",
    ".venv",
    "packer_cache",
    "artifacts",
    "result",
    "output",
    "audit/reports",
}

SKIP_SUFFIXES = {".qcow2", ".vhdx", ".ova", ".vmdk", ".zip", ".msi", ".pyc", ".lock"}

CANONICAL_ATTACK = "attack-faq-walkthrough.md"
CANONICAL_DEFEND = "defend-faq-walkthrough.md"

BOX_PATHS = {
    "cysvuln": {
        "dirs": ["docs/cysvulnserver"],
        "deploy_globs": [
            "docs/runbooks/deploy-cysvuln*.md",
            "infrastructure/packer/cysvuln/README.md",
            "docs/cysvulnserver/readme.md",
        ],
        "attack_aliases": [CANONICAL_ATTACK, "walkthrough.md"],
        "defend_aliases": [CANONICAL_DEFEND, "defend-faq-walkthrough.md"],
    },
    "ews": {
        "dirs": ["docs/ews", "targets/ews-win11"],
        "deploy_globs": [
            "docs/runbooks/deploy-windowsvm.md",
            "infrastructure/packer/ews/README.md",
            "docs/ews/README.md",
        ],
        "attack_aliases": [CANONICAL_ATTACK],
        "defend_aliases": [CANONICAL_DEFEND],
    },
    "asrep": {
        "dirs": ["docs/asrep"],
        "deploy_globs": [
            "docs/asrep/readme.md",
            "docs/asrep/reports/proxmox-deploy-recon.md",
            "infrastructure/packer/asrep/README.md",
        ],
        "attack_aliases": [CANONICAL_ATTACK, "walkthrough.md"],
        "defend_aliases": [CANONICAL_DEFEND, "blue-detection-faq.md"],
    },
}

LIBS = {
    "load_repo_env": "scripts/lib/load_repo_env.sh",
    "docker_stack": "scripts/lib/docker-stack.sh",
    "check_harness": "scripts/lib/check-harness.sh",
    "evidence_harness": "scripts/lib/evidence-harness.sh",
    "chain_env": "scripts/lib/chain_env.sh",
    "proxmox_ssh": "scripts/lib/proxmox-ssh.sh",
    "vnc_lab": "scripts/lib/vnc-lab.sh",
    "stress_campaign": "scripts/lib/stress-campaign.sh",
}

LOCAL_PROXMOX_PAIRS = [
    ("scripts/proxmox/deploy-cysvuln.sh", "scripts/build-cysvuln-local.sh"),
    ("scripts/proxmox/deploy-asrep.sh", "scripts/build-asrep-local.sh"),
    ("scripts/proxmox/baseline-snapshot-cysvuln.sh", "scripts/observability/baseline-snapshot.sh"),
    ("scripts/proxmox/baseline-snapshot-asrep.sh", "scripts/observability/baseline-snapshot-asrep.sh"),
    ("scripts/proxmox/deploy-wazuh-siem.sh", "scripts/wazuh-docker-up.sh"),
    ("scripts/proxmox/deploy-arkime-capture.sh", "scripts/arkime-docker-up.sh"),
    ("scripts/proxmox/sync-arkime-pcap.sh", "scripts/arkime-import-pcap.sh"),
    ("scripts/proxmox/verify-wazuh-siem.sh", None),
    ("scripts/proxmox/verify-arkime-capture.sh", "scripts/observability/vnc-pcap-proof.sh"),
    ("scripts/proxmox/rebuild-ews.sh", "scripts/hyperv/Build-SecretConEwsVhdx.ps1"),
]

ANSIBLE_CONCERNS = [
    ("Install-SecretConSysmon", "sysmon", "PARTIAL", "SecretCon.Bootstrap.psm1"),
    ("Install-SecretConWazuhAgent", "wazuh_agent", "MISSING", "SecretCon.Bootstrap.psm1"),
    ("Register-SecretConLogonSeederTask", "windows_startup_task", "MISSING", "SecretCon.Bootstrap.psm1"),
    ("TightVNC MSI + runtime registry", "tightvnc", "PARTIAL", "bootstrap_win.ps1"),
    ("Wazuh tvnserver tailer + SACL", "tightvnc", "PARTIAL", "bootstrap_win.ps1"),
    ("Unquoted service path LPE", "ews_lpe_service", "MISSING", "bootstrap_win.ps1"),
    ("Flag staging user/root", "flags", "MISSING", "bootstrap_win.ps1"),
    ("Defender relax scheduled task", "defender_relax", "MISSING", "bootstrap_win.ps1"),
    ("Autologon", "autologon", "MISSING", "bootstrap_win.ps1"),
    ("CysVuln EFS + AIE levers", "cysvuln_efs_installer", "MISSING", "bootstrap_cysvuln.ps1"),
    ("CysVuln AIE registry", "cysvuln_aie_levers", "MISSING", "bootstrap_cysvuln.ps1"),
    ("AS-REP promote + enite", "asrep_promote", "MISSING", "bootstrap_asrep.ps1"),
    ("AS-REP users and flags", "asrep_users_and_flags", "MISSING", "bootstrap_asrep.ps1"),
    ("DC promote", "dc_promote", "MISSING", "bootstrap_dc.ps1"),
]

EPHEMERAL_PATTERNS = [
    re.compile(r"probe-"),
    re.compile(r"reproduce-"),
    re.compile(r"proof"),
    re.compile(r"drain"),
    re.compile(r"debug"),
    re.compile(r"\d{4}-\d{2}-\d{2}"),
]


def repo_walk(root: Path) -> list[Path]:
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_parts = Path(dirpath).relative_to(root).parts
        if any(p in SKIP_DIRS for p in rel_parts) or any(
            p.startswith(".") and p not in (".claude",) for p in rel_parts
        ):
            dirnames[:] = []
            continue
        dirnames[:] = [
            d
            for d in dirnames
            if d not in SKIP_DIRS and not d.startswith("__pycache__")
        ]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix.lower() in SKIP_SUFFIXES:
                continue
            if "audit/reports" in str(p.relative_to(root)):
                continue
            out.append(p)
    return out


def rel(p: Path) -> str:
    try:
        return str(p.relative_to(REPO_ROOT))
    except ValueError:
        return str(p)


def write_report(name: str, data: Any, md_lines: list[str]) -> None:
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    json_path = REPORTS_DIR / f"{name}.json"
    md_path = REPORTS_DIR / f"{name}.md"
    json_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    md_path.write_text("\n".join(md_lines) + "\n", encoding="utf-8")


def audit_box_doc_coverage() -> tuple[dict[str, Any], list[str]]:
    result: dict[str, Any] = {}
    md = ["# Box documentation coverage", ""]
    for box, spec in BOX_PATHS.items():
        deploy_ok = False
        deploy_files: list[str] = []
        for pattern in spec["deploy_globs"]:
            for p in REPO_ROOT.glob(pattern):
                if p.is_file():
                    deploy_ok = True
                    deploy_files.append(rel(p))

        attack_file = None
        defend_file = None
        for d in spec["dirs"]:
            base = REPO_ROOT / d
            if not base.exists():
                continue
            for alias in spec["attack_aliases"]:
                candidate = base / alias
                if candidate.is_file():
                    attack_file = rel(candidate)
                    break
            for alias in spec["defend_aliases"]:
                candidate = base / alias
                if candidate.is_file():
                    defend_file = rel(candidate)
                    break

        result[box] = {
            "deployment": {"present": deploy_ok, "files": deploy_files},
            "attack_faq": {"present": attack_file is not None, "file": attack_file},
            "defend_faq": {"present": defend_file is not None, "file": defend_file},
        }
        md.append(f"## {box}")
        md.append(f"- deployment: {'PRESENT' if deploy_ok else 'MISSING'}")
        md.append(f"- attack-faq: {'PRESENT' if attack_file else 'MISSING'} ({attack_file or 'n/a'})")
        md.append(f"- defend-faq: {'PRESENT' if defend_file else 'MISSING'} ({defend_file or 'n/a'})")
        md.append("")
    return result, md


def audit_dry_clusters(files: list[Path]) -> tuple[dict[str, Any], list[str]]:
    script_sh = [p for p in files if rel(p).startswith("scripts/") and p.suffix == ".sh"]
    lib_usage: dict[str, list[str]] = {k: [] for k in LIBS}
    missing_lib: dict[str, list[str]] = {k: [] for k in LIBS}

    for p in script_sh:
        text = p.read_text(encoding="utf-8", errors="replace")
        r = rel(p)
        for key, lib_path in LIBS.items():
            if lib_path in text or Path(lib_path).name in text:
                lib_usage[key].append(r)
            elif key == "proxmox_ssh" and r.startswith("scripts/proxmox/"):
                missing_lib[key].append(r)
            elif key == "load_repo_env" and "source .env" in text and "load_repo_env" not in text:
                missing_lib[key].append(r)

    line_hashes: dict[str, list[str]] = defaultdict(list)
    for p in files:
        if not (p.suffix in (".sh", ".hcl", ".py") and "scripts/" in rel(p)):
            continue
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            stripped = line.strip()
            if len(stripped) < 40 or stripped.startswith("#"):
                continue
            h = hashlib.sha256(stripped.encode()).hexdigest()[:16]
            line_hashes[h].append(f"{rel(p)}:{i}")

    dup_clusters = {h: locs for h, locs in line_hashes.items() if len(locs) >= 3}

    data = {
        "lib_adoption": lib_usage,
        "should_use_lib": missing_lib,
        "duplicate_line_clusters": len(dup_clusters),
        "top_duplicate_samples": [
            {"hash": h, "locations": locs[:8]}
            for h, locs in sorted(dup_clusters.items(), key=lambda x: -len(x[1]))[:15]
        ],
    }
    md = ["# DRY / library adoption", ""]
    for key in LIBS:
        md.append(f"## {key}")
        md.append(f"- using: {len(lib_usage[key])}")
        md.append(f"- candidates: {len(missing_lib[key])}")
        if missing_lib[key][:5]:
            md.append(f"  - e.g. {', '.join(missing_lib[key][:5])}")
        md.append("")
    md.append(f"## Duplicate line clusters (3+ files): {len(dup_clusters)}")
    return data, md


def parse_example_env() -> set[str]:
    path = REPO_ROOT / "example.env"
    if not path.exists():
        return set()
    keys: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            keys.add(line.split("=", 1)[0].strip())
    return keys


def audit_env_coverage(files: list[Path]) -> tuple[dict[str, Any], list[str]]:
    documented = parse_example_env()
    env_re = re.compile(
        r"(?:\$\{([A-Z][A-Z0-9_]*)\}|"
        r":\s*\"\$\{([A-Z][A-Z0-9_]*)\}|"
        r"os\.environ\.get\(['\"]([A-Z][A-Z0-9_]*)['\"]|"
        r"os\.environ\[['\"]([A-Z][A-Z0-9_]*)['\"]|"
        r"getenv\(['\"]([A-Z][A-Z0-9_]*)['\"]|"
        r'env\(["\']([a-z][a-z0-9_]*)["\'])'
    )
    refs: dict[str, list[str]] = defaultdict(list)
    for p in files:
        if p.suffix not in (".sh", ".py", ".hcl", ".yml", ".md", ".ps1", ".psm1"):
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in env_re.finditer(text):
            var = next(g for g in m.groups() if g)
            if var.isupper():
                refs[var].append(rel(p))

    undocumented = sorted(v for v in refs if v not in documented)
    unused = sorted(documented - set(refs))

    data = {
        "documented_count": len(documented),
        "referenced_count": len(refs),
        "undocumented": {v: refs[v][:5] for v in undocumented[:50]},
        "documented_unused": unused[:30],
    }
    md = [
        "# Environment variable coverage",
        "",
        f"- Documented in example.env: {len(documented)}",
        f"- Referenced in tree: {len(refs)}",
        f"- Undocumented references: {len(undocumented)}",
        "",
    ]
    if undocumented[:20]:
        md.append("## Undocumented (sample)")
        for v in undocumented[:20]:
            md.append(f"- `{v}` — {refs[v][0]}")
    return data, md


def read_manifest(path: Path) -> set[str]:
    if not path.exists():
        return set()
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return set(lines)


def audit_manifest_parity() -> tuple[dict[str, Any], list[str]]:
    boxes = {
        "ews": REPO_ROOT / "infrastructure/packer/ews",
        "cysvuln": REPO_ROOT / "infrastructure/packer/cysvuln",
        "asrep": REPO_ROOT / "infrastructure/packer/asrep",
    }
    data: dict[str, Any] = {}
    md = ["# Provision manifest parity", ""]
    for box, base in boxes.items():
        prox = read_manifest(base / "provision-manifest-proxmox.txt")
        qemu = read_manifest(base / "provision-manifest-qemu.txt")
        if not prox and not qemu:
            # cysvuln uses different names
            prox = read_manifest(base / "provision-manifest-cysvuln.txt") or prox
            shared = read_manifest(base / "provision-manifest-shared.txt")
            qemu = qemu | shared
            prox = prox | shared
        only_proxmox = sorted(prox - qemu)
        only_qemu = sorted(qemu - prox)
        qemu_subset = qemu <= prox if prox else True
        data[box] = {
            "proxmox_count": len(prox),
            "qemu_count": len(qemu),
            "only_proxmox": only_proxmox,
            "only_qemu": only_qemu,
            "qemu_subset_of_proxmox": qemu_subset,
        }
        md.append(f"## {box}")
        md.append(f"- qemu subset of proxmox: {qemu_subset}")
        if only_proxmox:
            md.append(f"- proxmox-only: {only_proxmox}")
        md.append("")
    return data, md


def audit_local_proxmox_pairing() -> tuple[dict[str, Any], list[str]]:
    proxmox_scripts = sorted((REPO_ROOT / "scripts/proxmox").glob("*.sh"))
    prox_names = {p.name for p in proxmox_scripts}
    pairs = []
    for prox, local in LOCAL_PROXMOX_PAIRS:
        pairs.append(
            {
                "proxmox": prox,
                "local": local,
                "proxmox_exists": (REPO_ROOT / prox).exists(),
                "local_exists": local is not None and (REPO_ROOT / local).exists(),
            }
        )
    unpaired = [
        rel(p)
        for p in proxmox_scripts
        if not any(rel(p).endswith(Path(x[0]).name) for x in LOCAL_PROXMOX_PAIRS)
    ]
    data = {"pairs": pairs, "unpaired_proxmox_scripts": unpaired}
    md = ["# Local vs Proxmox script pairing", ""]
    for row in pairs:
        md.append(
            f"- `{row['proxmox']}` -> `{row['local'] or 'MISSING'}` "
            f"({'ok' if row['proxmox_exists'] and (row['local'] is None or row['local_exists']) else 'gap'})"
        )
    md.append("")
    md.append(f"## Unpaired Proxmox scripts ({len(unpaired)})")
    for u in unpaired[:25]:
        md.append(f"- {u}")
    return data, md


def audit_cross_references(files: list[Path]) -> tuple[dict[str, Any], list[str]]:
    scan_roots = ["scripts", "provisioning", "docs", "ansible", "infrastructure"]
    targets = [p for p in files if any(rel(p).startswith(r + "/") for r in scan_roots)]
    in_degree: dict[str, int] = defaultdict(int)
    rel_paths = [rel(p) for p in targets]
    rel_set = set(rel_paths)
    name_to_paths: dict[str, list[str]] = defaultdict(list)
    for rp in rel_paths:
        name_to_paths[Path(rp).name].append(rp)

    for p in targets:
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        r = rel(p)
        seen: set[str] = set()
        for other_rp in rel_set:
            if other_rp == r:
                continue
            if other_rp in text or Path(other_rp).name in text:
                seen.add(other_rp)
        for other_rp in seen:
            in_degree[other_rp] += 1

    orphans = sorted([k for k in rel_paths if in_degree.get(k, 0) == 0])[:80]
    data = {
        "files_scanned": len(targets),
        "orphan_candidates_in_degree_0": orphans,
        "orphan_count": len(orphans),
    }
    md = ["# Cross-references", "", f"Orphan candidates (in-degree 0): {len(orphans)}", ""]
    for o in orphans[:40]:
        md.append(f"- {o}")
    return data, md


def audit_ephemeral_flags(files: list[Path]) -> tuple[dict[str, Any], list[str]]:
    flagged: list[dict[str, str]] = []
    for p in files:
        r = rel(p)
        name = p.name
        for pat in EPHEMERAL_PATTERNS:
            if pat.search(name) or pat.search(r):
                flagged.append({"path": r, "reason": pat.pattern})
                break
    data = {"flagged_count": len(flagged), "samples": flagged[:60]}
    md = ["# Ephemeral / scratch flags", "", f"Total flagged: {len(flagged)}", ""]
    for row in flagged[:40]:
        md.append(f"- `{row['path']}` ({row['reason']})")
    return data, md


def audit_ansible_migration() -> tuple[dict[str, Any], list[str]]:
    roles_dir = REPO_ROOT / "ansible" / "roles"
    existing_roles = sorted(
        d.name for d in roles_dir.iterdir() if d.is_dir() and (d / "tasks").exists()
    ) if roles_dir.exists() else []
    rows = []
    for concern, role, status, source in ANSIBLE_CONCERNS:
        actual = status
        if role in existing_roles and status == "MISSING":
            actual = "PARTIAL"
        rows.append(
            {
                "concern": concern,
                "role": role,
                "status": actual,
                "powershell_source": source,
            }
        )
    covered = sum(1 for r in rows if r["status"] == "COVERED")
    partial = sum(1 for r in rows if r["status"] == "PARTIAL")
    missing = sum(1 for r in rows if r["status"] == "MISSING")
    data = {
        "rows": rows,
        "summary": {"covered": covered, "partial": partial, "missing": missing},
        "existing_roles": existing_roles,
    }
    md = [
        "# Ansible migration coverage",
        "",
        f"COVERED: {covered} | PARTIAL: {partial} | MISSING: {missing}",
        "",
        "| Concern | Role | Status | PS source |",
        "|---------|------|--------|-----------|",
    ]
    for r in rows:
        md.append(f"| {r['concern']} | {r['role']} | {r['status']} | {r['powershell_source']} |")
    return data, md


def print_summary() -> None:
    print("SecretCon repo-audit summary")
    print(f"Reports: {REPORTS_DIR.relative_to(REPO_ROOT)}/")
    for name in sorted(REPORTS_DIR.glob("*.md")):
        print(f"  - {name.name}")


def main() -> int:
    parser = argparse.ArgumentParser(description="SecretCon repository audit")
    parser.add_argument(
        "dimension",
        nargs="?",
        default="all",
        choices=[
            "all",
            "box-doc-coverage",
            "dry-clusters",
            "env-coverage",
            "manifest-parity",
            "local-proxmox-pairing",
            "cross-references",
            "ephemeral-flags",
            "ansible-migration-coverage",
        ],
    )
    parser.add_argument("--baseline", action="store_true", help="Copy reports to audit/reports/baseline/")
    args = parser.parse_args()

    if not REPO_ROOT.joinpath("flake.nix").exists():
        print(f"[!] Expected repo root at {REPO_ROOT}", file=sys.stderr)
        return 2

    files = repo_walk(REPO_ROOT)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    runners = {
        "box-doc-coverage": lambda: audit_box_doc_coverage(),
        "dry-clusters": lambda: audit_dry_clusters(files),
        "env-coverage": lambda: audit_env_coverage(files),
        "manifest-parity": lambda: audit_manifest_parity(),
        "local-proxmox-pairing": lambda: audit_local_proxmox_pairing(),
        "cross-references": lambda: audit_cross_references(files),
        "ephemeral-flags": lambda: audit_ephemeral_flags(files),
        "ansible-migration-coverage": lambda: audit_ansible_migration(),
    }

    dims = list(runners.keys()) if args.dimension == "all" else [args.dimension]

    for dim in dims:
        data, md = runners[dim]()
        if isinstance(data, tuple):
            data, md = data
        header = [f"Generated: {ts}", ""]
        write_report(dim, {"generated": ts, **(data if isinstance(data, dict) else {"data": data})}, header + md)

    if args.baseline:
        baseline = REPO_ROOT / "audit" / "reports" / "baseline"
        baseline.mkdir(parents=True, exist_ok=True)
        for p in REPORTS_DIR.glob("*"):
            if p.is_file() and p.parent == REPORTS_DIR:
                (baseline / p.name).write_bytes(p.read_bytes())

    print_summary()
    return 0


if __name__ == "__main__":
    sys.exit(main())
