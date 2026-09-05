# Security

Report a vulnerability in this action, or in the service it talks to, to contact@sixi.ai. Sixi's
disclosure terms and the current security contact are published at
https://sixi.ch/.well-known/security.txt.

What this action handles that matters: a pipeline token for the hosted API, and optionally a
credential for the agent under test. Both reach the script through the environment, never through a
shell line, and the target credential is stored encrypted with the scan and masked in every API
response. The SARIF the action writes never carries a payload, the target's reply or the attacker's
notes.
