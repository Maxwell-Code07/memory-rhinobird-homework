@echo off
rem Windows wrapper so soak.mjs can spawn the mock like a real binary.
node "%~dp0mock-hermes.mjs" %*
