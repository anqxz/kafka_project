# Claude Skills — Integration & Usage

This document describes recommended prompt patterns, utilities, and integration notes for using Claude (or similar assistant models) with the kafka_project codebase.

## Purpose
- Capture useful Claude prompts and structured patterns for automation, code review, and documentation generation.
- Provide reproducible examples for contributors who want to integrate Claude-style workflows into their development process.

## Suggested Skills / Prompts

### 1) Project Overview & Onboarding
Prompt:
- "Summarize the kafka_project repository: what each folder contains, how to run the example producer and consumer locally using Docker Compose, and any notable scripts."

Output expectations:
- Short summary of repo layout, prerequisites, quickstart steps, and pointers to architecture diagram.

### 2) Code Explanation / Walkthrough
Prompt:
- "Explain the producer implementation in src/producer.py: list entry points, key functions, and environment variables needed."

Output expectations:
- Function list, input/output topics, config keys, and suggested tests.

### 3) Creating Documentation (wiki pages)
Prompt:
- "Generate a concise wiki page explaining how to run the project locally with Docker Compose and how to run the Python consumer with sample env variables."

Output expectations:
- Ready-to-paste markdown with commands and examples.

### 4) Generating Tests / Examples
Prompt:
- "Generate a simple pytest unit test for the function `parse_message` in src/utils.py with a normal and an edge-case input."

Output expectations:
- Two pytest functions with fixtures and expected assertions.

## Safety & Data Handling Best Practices
- Do not paste secrets (API keys, passwords) in prompts.
- Use placeholders for credentials and show how to load from environment variables or secret managers.
- Prefer small, well-scoped prompts for code changes — include only necessary files or snippets.

## Integration Notes
- Keep generated code reviewed by a human; the assistant can introduce subtle bugs or import/style differences.
- Store frequently-used prompts in this wiki for consistent outputs across contributors.
- For CI automation: use generated test stubs as a starting point; run them locally before committing.

## Example Prompt Template (for contributors)
```
Task: Add a README section for src/transform.py describing inputs, outputs, and environment variables.
Repository: kafka_project
Files to consider: src/transform.py
Tone: concise, actionable, bullet points
```

## Contact
- Repo owner: @anqxz
- Update this page with new prompt templates or common pitfalls discovered by the team.
