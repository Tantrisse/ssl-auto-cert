# SSL Auto Cert

## What is it ?

This simple script will :

- Generate a root CA if no one exists
- If a root CA if generated, add it to the system, firefox and chrome DB
- Ask for new domain(s) to certify
- Add those domains to your hosts file (mapped to 127.0.0.1)
- Read your host file and parse all domains
- Create a certificate for all the domains found and sign it with the ROOT CA
- If specified in .env, trigger a reload of [Traefik 2.0](https://docs.traefik.io/https/tls/#user-defined)

## Installation

- Clone this repo
- Grab a drink
