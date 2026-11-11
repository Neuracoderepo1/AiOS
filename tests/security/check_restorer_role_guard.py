#!/usr/bin/env python3
"""Fail closed if the Part D migration contains executable ALTER ROLE aios_restorer."""
from __future__ import annotations
import argparse
import re
from pathlib import Path

TARGET = re.compile(r'\bALTER\s+(?:ROLE|USER)\s+(?:IF\s+EXISTS\s+)?(?:aios_restorer|"aios_restorer")(?=\s|;|$)', re.I)

def strip_comments(sql: str) -> str:
    # Preserve quoted strings (including dynamic SQL) while removing SQL comments.
    out=[]; i=0; n=len(sql); state="normal"
    while i<n:
        if state=="normal":
            if sql.startswith("--",i):
                state="line"; out.extend("  "); i+=2
            elif sql.startswith("/*",i):
                state="block"; out.extend("  "); i+=2
            elif sql[i]=="'":
                state="single"; out.append(sql[i]); i+=1
            elif sql[i]=='"':
                state="double"; out.append(sql[i]); i+=1
            else: out.append(sql[i]); i+=1
        elif state=="line":
            if sql[i]=="\n": state="normal"; out.append("\n")
            else: out.append(" ")
            i+=1
        elif state=="block":
            if sql.startswith("/*",i): out.extend("  "); i+=2
            elif sql.startswith("*/",i): out.extend("  "); i+=2; state="normal"
            else: out.append("\n" if sql[i]=="\n" else " "); i+=1
        elif state=="single":
            out.append(sql[i])
            if sql[i]=="'" and i+1<n and sql[i+1]=="'": out.append(sql[i+1]); i+=2
            elif sql[i]=="'": state="normal"; i+=1
            elif sql[i]=="\\":
                if i+1<n: out.append(sql[i+1]); i+=2
                else: i+=1
            else: i+=1
        else:
            out.append(sql[i])
            if sql[i]=='"' and i+1<n and sql[i+1]=='"': out.append(sql[i+1]); i+=2
            elif sql[i]=='"': state="normal"; i+=1
            else: i+=1
    return "".join(out)

def violations(sql: str) -> list[str]:
    # String literals are preserved, so dynamic EXECUTE statements are checked as well.
    hits=list(TARGET.finditer(strip_comments(sql)))
    return [f"forbidden ALTER ROLE aios_restorer at offset {m.start()}" for m in hits]

def self_test() -> None:
    cases = [
      ("ALTER ROLE aios_restorer NOLOGIN", True),
      ('alter\n user\n "aios_restorer" nologin', True),
      ("DO $$ BEGIN EXECUTE 'ALTER ROLE aios_restorer LOGIN'; END $$;", True),
      ("-- ALTER ROLE aios_restorer LOGIN\nSELECT 1;", False),
      ("/* ALTER ROLE aios_restorer LOGIN */ SELECT 1;", False),
      ("ALTER ROLE another_role NOLOGIN;", False),
      ("ALTER ROLE IF EXISTS aios_restorer LOGIN;", True),
      ("ALTER USER IF EXISTS aios_restorer LOGIN;", True),
      ("ALTER /* comment */ ROLE IF /* comment */ EXISTS aios_restorer LOGIN;", True),
    ]
    for source, expected in cases:
        actual=bool(violations(source))
        if actual != expected:
            raise SystemExit(f"guard self-test failed: expected {expected}, got {actual}: {source!r}")
    print(f"PASS: {len(cases)} restoration ALTER ROLE guard mutation cases")

def main() -> None:
    p=argparse.ArgumentParser()
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--migration", type=Path)
    a=p.parse_args()
    if a.self_test: self_test()
    if a.migration:
        found=violations(a.migration.read_text(encoding="utf-8"))
        if found: raise SystemExit("\n".join(found))
        print(f"PASS: no executable ALTER ROLE aios_restorer in {a.migration}")
    if not a.self_test and not a.migration: p.error("provide --self-test and/or --migration")

if __name__=="__main__": main()
