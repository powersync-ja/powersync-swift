# CustomCheckpointDemo

A small SwiftPM command line demo for custom checkpoint requests.

The connector is shaped around the
[powersync-ja/powersync-nodejs-backend-todolist-demo](https://github.com/powersync-ja/powersync-nodejs-backend-todolist-demo)
Node.js todo backend. It uses that backend's auth, batch upload, and checkpoint request endpoints.

## Run

```sh
BACKEND_URL=http://localhost:6060 \
swift run CustomCheckpointDemo
```

`BACKEND_URL` defaults to `http://localhost:6060`, `POWERSYNC_URL` defaults to
`http://localhost:8080`, and `USER_ID` defaults to
`00000000-0000-4000-8000-000000000001`. If set explicitly, `POWERSYNC_URL` must be an absolute
`http` or `https` URL and `USER_ID` should be a UUID for the Node.js todo backend's default
Postgres schema.

The demo uses an in-memory local database. If `USER_ID` is set to a non-UUID value, the demo prints
a warning and falls back to the default UUID.

## Backend Contract

Existing endpoints used by the demo:

- `GET /api/auth/token?user_id=<user id>` returns `{ "token": "...", "powersync_url": "..." }`.
- `POST /api/data` receives `{ "batch": [{ "op": "PUT|PATCH|DELETE", "table": "...", "data": { "id": "...", ... } }] }`.

Checkpoint request endpoint used by the demo:

- `POST /api/data/checkpoint-request`
- Request body: `{ "user_id": "...", "client_id": "...", "checkpoint_request_id": "..." }`
- Response body: `{ "checkpoint_request_id": "..." }`

The returned checkpoint request ID should be the effective request state accepted by the backend.
Usually this is the posted ID, but if the backend already has a newer request recorded for the same
client it should return that newer ID.

The SDK does not attach the PowerSync sync token to `postCheckpointRequest` calls. If this endpoint
needs application backend authentication, the connector should fetch or cache a suitable backend
token and add it to the request itself.
