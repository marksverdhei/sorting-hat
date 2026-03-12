# Architecture Decision Record: API Gateway

## Status
Accepted

## Context
We need a single entry point for our microservices to handle auth, rate limiting, and routing.

## Decision
Use Kong as our API gateway deployed on Kubernetes.

## Consequences
- Centralized authentication
- Easier rate limiting and monitoring
- Additional infrastructure component to maintain
