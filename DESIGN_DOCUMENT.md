# Design Document — Account Service Withdrawal API

## Context

`account_service` administra cuentas y sus balances.

Necesitamos permitir que un cliente solicite el retiro de fondos de una cuenta.

Debido a retries, timeouts y requests concurrentes, una misma operación lógica podría recibirse múltiples veces. El sistema debe evitar descontar el balance más de una vez.

---

## Goals

El endpoint debe:

* Permitir retirar fondos de una cuenta.
* Garantizar idempotencia.
* Manejar requests concurrentes de manera segura.
* Evitar balances negativos.
* Devolver consistentemente el resultado de un request repetido.
* Proporcionar errores claros al caller.

## Non-goals

Para mantener el ejercicio acotado:

* `amount` será un entero.
* No habrá múltiples monedas.
* No habrá transferencias entre cuentas.
* No implementaremos autenticación/autorización.
* No implementaremos integración con un payment provider externo.

---

# API Contract

## Endpoint

```http
POST /v1/accounts/{account_id}/withdrawals
```

## Request

```json
{
  "idempotency_key": "1239867",
  "amount": 500
}
```

## Parameters

| Campo             | Tipo           | Obligatorio | Descripción                                           |
| ----------------- | -------------- | ----------: | ----------------------------------------------------- |
| `account_id`      | UUID / Integer |          Sí | Cuenta sobre la que se realiza el retiro              |
| `idempotency_key` | String         |          Sí | Identificador idempotente proporcionado por el caller |
| `amount`          | Integer        |          Sí | Cantidad a retirar                                    |

---

# Idempotency Semantics

Para una cuenta determinada, un `idempotency_key` identifica exactamente una operación lógica de retiro.

La combinación:

```text
(account_id, idempotency_key)
```

debe ser única.

Ejemplo:

```text
POST account=442 idempotency_key=A amount=500
POST account=442 idempotency_key=A amount=700
```

Esto se considera un conflicto de idempotencia y no debería procesarse como una operación diferente.

Una posible respuesta sería:

```http
409 Conflict
```

> **Nota:** este escenario se identificó durante el diseño, pero no forma parte de la implementación inicial.

---

# Business Invariants

## Amount

```text
amount > 0
```

La cantidad a retirar siempre debe ser positiva.

## Sufficient balance

```text
balance >= amount
```

La cantidad a retirar debe ser menor o igual que el balance disponible.

## Non-negative balance

```text
balance >= 0
```

Una cuenta nunca puede tener un balance negativo.

## Idempotent withdrawal

```text
(account_id, idempotency_key)
```

Una operación lógica de withdrawal sólo puede descontar fondos como máximo una vez.

## Concurrent withdrawals

Ejemplo:

```text
balance = 500

Request A: withdraw 400
Request B: withdraw 400
```

Withdrawals concurrentes no pueden consumir los mismos fondos.

Sólo uno puede ganar.

Por lo tanto:

> La validación del balance y su actualización deben comportarse como una operación atómica.

---

# Error Semantics

## Successful withdrawal

```http
200 OK
```

```json
{
  "result": "success",
  "balance_after_withdrawal": 1000
}
```

## Invalid request

```http
400 Bad Request
```

```json
{
  "result": "bad_request",
  "message": "amount is required"
}
```

## Insufficient funds

```http
422 Unprocessable Content
```

```json
{
  "result": "insufficient_funds",
  "current_balance": 300
}
```

## Account not found

```http
404 Not Found
```

## Internal server error

```http
500 Internal Server Error
```

```json
{
  "result": "internal_server_error"
}
```

Los detalles internos del error deberían escribirse en logs en lugar de regresarse al cliente.

Esta decisión puede discutirse dependiendo de los requerimientos de observabilidad y debugging del sistema.

---

# Data Model

## Account

| Campo     | Descripción                        |
| --------- | ---------------------------------- |
| `id`      | Identificador interno de la cuenta |
| `balance` | Balance disponible                 |

## Withdrawal

| Campo               | Descripción                                               |
| ------------------- | --------------------------------------------------------- |
| `id`                | Identificador interno del withdrawal                      |
| `account_id`        | Cuenta asociada                                           |
| `idempotency_key`   | Identificador de la operación proporcionado por el caller |
| `amount`            | Cantidad retirada                                         |
| `resulting_balance` | Balance resultante después de esta operación              |
| `created_at`        | Timestamp de creación                                     |

### Constraint

```text
UNIQUE(account_id, idempotency_key)
```

Esta combinación también debe estar indexada porque se utilizará continuamente para buscar withdrawals previamente procesados.

---

# Transaction Boundary

Las operaciones relevantes son:

```text
find withdrawal
find account
validate balance
decrement balance
create withdrawal
```

Pregunta principal:

> ¿Cuáles de estas operaciones necesitan pertenecer a la misma transacción?

La validación del balance debe ocurrir sobre el estado autoritativo de la cuenta y dentro de la misma transacción que modifica el balance.

Esto evita tomar decisiones basadas en un valor potencialmente desactualizado proveniente de una read replica con replica lag.

El flujo final es aproximadamente:

```text
validate request
        ↓
BEGIN TRANSACTION
        ↓
find Account WITH LOCK
        ↓
find existing Withdrawal
        ↓
validate account state
        ↓
validate sufficient balance
        ↓
update Account
        ↓
create Withdrawal
        ↓
COMMIT
```

El row-level lock se libera después del `COMMIT` o `ROLLBACK`.

---

# Failure Scenarios

Se deben considerar al menos los siguientes escenarios:

1. Duplicate sequential request.
2. Duplicate concurrent request.
3. Two different withdrawals competing for the same balance.
4. Process crashes before modifying balance.
5. Process crashes after modifying balance.
6. Database transaction fails.
7. Same idempotency key arrives with a different amount.

Para cada escenario debemos preguntarnos:

* ¿Qué observa el caller?
* ¿Qué queda persistido?
* ¿Es seguro hacer retry?

---

# Concurrency and Locking Analysis

## Failure mode without locking

Supongamos:

```text
Account balance = 500
```

Dos transacciones concurrentes:

| TX A               | TX B               |
| ------------------ | ------------------ |
| read balance → 500 | read balance → 500 |
| `500 >= 400` ✓     | `500 >= 400` ✓     |
| balance = 100      | balance = 100      |
| commit             | commit             |

Cada transacción hizo individualmente algo aparentemente correcto.

Globalmente, sin embargo, acabamos de aceptar:

```text
400 + 400 = 800
```

en withdrawals cuando la cuenta solamente tenía:

```text
500
```

Necesitamos evitar que dos transacciones puedan tomar simultáneamente una decisión basada en el mismo balance antiguo.

---

## Row-level pessimistic locking

El request que obtenga primero acceso exclusivo a cierto `account_id` debe bloquear ese registro mientras toma la decisión y actualiza el balance.

Conceptualmente:

```text
lock/find Account
        ↓
read authoritative balance
        ↓
validate balance
        ↓
update balance
        ↓
create Withdrawal
        ↓
commit
        ↓
lock released
```

Para una cuenta determinada, solamente una transacción puede tomar decisiones sobre su balance a la vez.

Esto permite que diferentes cuentas sigan siendo procesadas concurrentemente.

---

## Trade-offs of row-level locking

Si una transacción mantiene el lock durante demasiado tiempo pueden aparecer:

* Contention.
* Mayor latency.
* Timeouts.
* Deadlocks.

Por esta razón debemos mantener las transacciones pequeñas y evitar trabajo innecesario mientras el registro está bloqueado.

En este escenario todo ocurre dentro de la misma base de datos, por lo que el mecanismo se mantiene relativamente simple.

---

## Authoritative reads

El chequeo del balance debe ocurrir en la base de datos principal dentro de la misma transacción que actualiza el balance.

No debemos tomar una decisión financiera como:

```text
balance >= amount
```

utilizando una read replica que pueda presentar replica lag.

---

## Timestamps do not establish execution order

Ejemplo:

```text
A created_at = 10:00:00.001
B created_at = 10:00:00.002
```

Esto no garantiza que A haya adquirido primero el lock.

En sistemas concurrentes no debemos confiar en timestamps para decidir quién ejecuta primero, salvo que explícitamente estemos construyendo un mecanismo de ordering.

Para este ejercicio solamente necesitamos garantizar:

> Como máximo una operación puede consumir los fondos disponibles cuando varias operaciones compiten por el mismo balance.

---

# Locking Strategy

El `account_service` es relativamente sencillo y no esperamos cientos de withdrawals concurrentes sobre la misma cuenta por segundo.

Alternativas consideradas:

* Pessimistic locking.
* Optimistic locking.

## Requirements

Queremos:

* Correctness.
* Implementación fácil de entender.
* Transacciones pequeñas.
* Comportamiento predecible.

Para este escenario se eligió:

> **Pessimistic row-level locking**

porque priorizamos correctness y simplicidad, y esperamos baja contención por cuenta.

---

# Lock Lifetime

Secuencia inicial considerada:

```text
find/create Withdrawal
find Account
validate amount
validate balance
update Account
mark Withdrawal successful
```

La validación de `amount` debe ocurrir antes de entrar a la sección protegida porque no depende del estado de la cuenta.

Esto reduce el tiempo durante el cual mantenemos abierta la transacción.

El flujo protegido queda:

```text
validate request

BEGIN TRANSACTION
        ↓
find Account WITH LOCK
        ↓
find Withdrawal
        ↓
validate balance
        ↓
update Account
        ↓
create Withdrawal
        ↓
COMMIT
```

---

# Duplicate Concurrent Requests

Consideremos dos requests:

```text
Request A                  Request B

account=1                  account=1
idempotency_key=X          idempotency_key=X
amount=400                 amount=400
```

El comportamiento deseado es:

```text
Request A
    ↓
locks Account
    ↓
Withdrawal X does not exist
    ↓
updates balance
    ↓
creates Withdrawal X
    ↓
COMMIT
```

Mientras tanto:

```text
Request B
    ↓
waits for Account lock
    ↓
acquires Account lock
    ↓
Withdrawal X already exists
    ↓
returns stored result
```

El segundo request no vuelve a descontar el balance.

---

# Why Store `resulting_balance`?

Supongamos:

```text
Initial balance = 1000
```

Primer withdrawal:

```text
idempotency_key = A
amount = 700
resulting_balance = 300
```

Posteriormente ocurre otra operación:

```text
amount = 300
current account balance = 0
```

Si después vuelve a llegar:

```text
idempotency_key = A
amount = 700
```

el sistema debe devolver el resultado original:

```text
resulting_balance = 300
```

y no el balance actual de la cuenta.

Esto permite que un retry de la misma operación observe un resultado consistente.

---

# Trade-offs

## Pessimistic locking

Se utiliza pessimistic locking porque no esperamos cientos de requests concurrentes intentando modificar el balance de la misma cuenta.

Ventajas:

* Modelo de concurrencia sencillo.
* Fácil de razonar.
* Evita decisiones simultáneas basadas en un balance antiguo.
* Prioriza correctness.

Desventajas:

* Serializa modificaciones sobre la misma cuenta.
* Puede generar contention.
* Puede incrementar latency bajo alta concurrencia.
* Requiere mantener pequeñas las transacciones.

Si el sistema tuviera cuentas extremadamente hot o un workload similar a sistemas de trading de alta frecuencia, habría que reevaluar esta decisión.

---

# Open Questions

* ¿Cómo debería manejarse la reutilización de un `idempotency_key` con un `amount` diferente?
* ¿Durante cuánto tiempo deben conservarse los registros de idempotencia?
* ¿Qué estrategia de autenticación debería utilizar el servicio?
* ¿Cómo se debería realizar authorization para garantizar que un caller puede retirar fondos de una cuenta determinada?
* ¿Cómo cambiaría el diseño si el withdrawal requiriera comunicarse con un servicio externo?
* ¿Qué estrategia usaríamos si la contención por cuenta aumentara significativamente?

---

# Tests

## Sequential behavior

Se ejecutaron manualmente las siguientes pruebas.

### Initial state

```text
balance = 1000
```

### Withdrawal 1

```text
idempotency_key = 122323
amount = 700
```

Resultado:

```text
resulting_balance = 300
```

### Idempotent retry

Se repite:

```text
idempotency_key = 122323
amount = 700
```

Resultado:

```text
No vuelve a descontar.
Devuelve resulting_balance = 300.
```

### Different withdrawal

Otra operación retira:

```text
amount = 300
```

Resultado:

```text
current account balance = 0
```

### Retry after account state changed

Se vuelve a enviar:

```text
idempotency_key = 122323
amount = 700
```

Resultado:

```text
resulting_balance = 300
```

aunque el balance actual de la cuenta sea:

```text
0
```

Esto confirma que el resultado del withdrawal se conserva independientemente de operaciones posteriores.

---

# Pending Tests

Aún deben validarse explícitamente:

1. Dos withdrawals diferentes concurrentes compitiendo por el mismo balance.
2. Dos requests concurrentes con el mismo `idempotency_key`.
3. Rollback cuando falla la creación del `Withdrawal`.
4. Account inexistente.
5. `amount <= 0`.
6. Database failure dentro de la transacción.
