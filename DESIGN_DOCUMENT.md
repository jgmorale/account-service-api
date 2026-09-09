# Account Service — Withdrawal API Design

## Overview

`account_service` manages account balances and exposes an API for withdrawing funds.

The main design goals are:

* prevent duplicate withdrawals caused by retries;
* prevent concurrent withdrawals from overspending an account;
* keep balance updates and withdrawal records consistent;
* return stable results for repeated idempotent requests.

The initial implementation intentionally keeps the system small: all relevant state is stored in a single relational database and no external payment provider is involved.

---

## API

### Endpoint

```http
POST /v1/accounts/{account_id}/withdrawals
```

### Request

```json
{
  "idempotency_key": "1239867",
  "amount": 500
}
```

### Parameters

| Field             | Type    | Required | Description                                          |
| ----------------- | ------- | -------: | ---------------------------------------------------- |
| `account_id`      | Integer |      Yes | Account to withdraw funds from                       |
| `idempotency_key` | String  |      Yes | Caller-provided identifier for the logical operation |
| `amount`          | Integer |      Yes | Amount to withdraw                                   |

### Success Response

```http
200 OK
```

```json
{
  "result": "success",
  "balance_after_withdrawal": 500
}
```

---

## Scope

### Goals

* Support account withdrawals.
* Guarantee idempotent processing.
* Prevent negative balances.
* Handle concurrent withdrawals safely.
* Return the original result when a successful request is retried.

### Non-goals

* Authentication and authorization.
* Multiple currencies.
* Account-to-account transfers.
* External payment provider integration.
* Decimal monetary representation.
* Idempotency-key payload validation beyond the initial implementation.

---

## Data Model

### Account

| Field     | Description               |
| --------- | ------------------------- |
| `id`      | Primary key               |
| `balance` | Current available balance |

### Withdrawal

| Field               | Description                                      |
| ------------------- | ------------------------------------------------ |
| `id`                | Primary key                                      |
| `account_id`        | Associated account                               |
| `idempotency_key`   | Caller-provided operation identifier             |
| `amount`            | Withdrawn amount                                 |
| `resulting_balance` | Account balance immediately after the withdrawal |
| `created_at`        | Creation timestamp                               |

### Constraints

```text
UNIQUE(account_id, idempotency_key)
```

The unique composite index serves two purposes:

1. prevents duplicate logical withdrawals;
2. supports efficient idempotency lookups.

`Withdrawal.account_id` is also enforced as a foreign key to `Account`.

---

## Business Invariants

The implementation must preserve the following invariants:

```text
amount > 0
```

```text
balance >= 0
```

```text
A logical withdrawal may affect the balance at most once.
```

```text
Two concurrent withdrawals must not spend the same available funds.
```

For example:

```text
balance = 500

Withdrawal A = 400
Withdrawal B = 400
```

At most one withdrawal may succeed.

---

## Idempotency

For a given account, the pair:

```text
(account_id, idempotency_key)
```

identifies one logical withdrawal.

Example:

```text
Request 1:
account_id = 1
idempotency_key = A
amount = 700
```

If the request succeeds with:

```text
resulting_balance = 300
```

then any retry using the same idempotency key returns the stored withdrawal result without modifying the balance again.

The response is based on `Withdrawal.resulting_balance`, not the account's current balance.

This matters because later operations may change the account:

```text
Initial balance                 1000
Withdrawal A                    -700
Result after A                   300
Withdrawal B                    -300
Current balance                   0
Retry Withdrawal A              -> returns 300
```

The retry observes the result of the original logical operation.

---

## Transaction and Concurrency Model

Balance validation and modification must happen atomically against the authoritative account state.

The withdrawal flow is:

```text
validate request
        ↓
BEGIN TRANSACTION
        ↓
lock Account row
        ↓
find existing Withdrawal
        ↓
if found → return stored result
        ↓
validate sufficient balance
        ↓
update Account balance
        ↓
create Withdrawal
        ↓
COMMIT
```

The account row is acquired using a pessimistic row-level lock.

The lock remains held until the transaction commits or rolls back.

---

## Why Pessimistic Locking?

Without locking, two concurrent transactions may both observe the same balance:

| Transaction A      | Transaction B      |
| ------------------ | ------------------ |
| read balance = 500 | read balance = 500 |
| validate 400 ≤ 500 | validate 400 ≤ 500 |
| set balance = 100  | set balance = 100  |
| commit             | commit             |

Both withdrawals would appear successful even though the account only had enough funds for one.

With row-level locking:

```text
Transaction A
    ↓
locks Account
    ↓
reads balance = 500
    ↓
withdraws 400
    ↓
balance = 100
    ↓
commit
```

Transaction B waits for the same account row:

```text
Transaction B
    ↓
waits
    ↓
acquires lock after A commits
    ↓
reads balance = 100
    ↓
insufficient funds
```

Different accounts can still be processed concurrently.

### Trade-off

Pessimistic locking serializes writes for the same account and may introduce:

* contention;
* increased latency;
* lock timeouts;
* deadlocks.

For this service, correctness and simplicity are prioritized, and high write contention on an individual account is not expected.

If contention became significant, optimistic concurrency or atomic conditional updates could be evaluated.

---

## Transaction Boundary

The following operations belong to the same transaction:

```text
lock account
read current balance
check idempotency
validate sufficient funds
update balance
create withdrawal
```

This guarantees that the system cannot persist:

```text
balance updated
+
withdrawal missing
```

or:

```text
withdrawal created
+
balance not updated
```

If any database operation fails, the entire transaction rolls back.

Validation that does not depend on database state, such as:

```text
amount > 0
```

is performed before opening the transaction to minimize lock duration.

---

## Read Consistency

Balance validation must use the primary database participating in the transaction.

A read replica may contain stale state due to replication lag and therefore must not be used to decide whether funds are available.

The correctness decision:

```text
balance >= amount
```

must use authoritative state.

---

## Error Semantics

| Scenario                     |                 HTTP Status |
| ---------------------------- | --------------------------: |
| Successful withdrawal        |                    `200 OK` |
| Invalid request              |           `400 Bad Request` |
| Account not found            |             `404 Not Found` |
| Insufficient funds           | `422 Unprocessable Content` |
| Idempotency conflict (future)|              `409 Conflict` |
| Unexpected internal failure  | `500 Internal Server Error` |

Internal infrastructure details should be logged rather than exposed to API clients.

---

## Failure Scenarios

The design should remain safe under the following conditions:

1. Sequential duplicate requests.
2. Concurrent duplicate requests.
3. Concurrent withdrawals competing for the same balance.
4. Failure before the balance update.
5. Failure after the balance update but before withdrawal creation.
6. Database transaction failure.
7. Reuse of an idempotency key with different request parameters.

For each failure mode, the key questions are:

* What does the caller observe?
* What state is persisted?
* Is retrying safe?

---

## Validated Behavior

The following behavior was manually verified.

Initial state:

```text
balance = 1000
```

First withdrawal:

```text
idempotency_key = 122323
amount = 700
resulting_balance = 300
```

Retrying the same request:

```text
idempotency_key = 122323
amount = 700
```

returns:

```text
resulting_balance = 300
```

without modifying the account again.

A second independent withdrawal:

```text
amount = 300
```

changes the current account balance to:

```text
0
```

Retrying the original request still returns:

```text
resulting_balance = 300
```

which confirms stable idempotent response semantics.

---

## Future Considerations

The following concerns are intentionally deferred:

* binding an idempotency key to the complete request payload;
* idempotency record retention policies;
* authentication and authorization;
* account ownership validation;
* external payment provider integration;
* alternative concurrency strategies under high contention;
* monetary representation using currency-aware decimal values.
