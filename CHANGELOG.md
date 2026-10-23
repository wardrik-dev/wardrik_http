# Changelog

## 0.1.0 (unreleased)

- Every operation of `WardrikProtocol` at its route, built from the OpenAPI document, each run with
  `Wardrik.run/3`.
- API tokens as `Authorization: Bearer`, or your own `WardrikHTTP.Authenticator`.
- Agents' events as server-sent events, resumed after `Last-Event-ID`, kept open with a comment,
  and ended once the token is revoked.
- Webhooks, read as they came, with `WardrikHTTP.BodyReader` for apps that parse bodies first.
- The sign-in pages at `/oauth/`, and the OpenAPI document at `/v1/openapi.json`.
