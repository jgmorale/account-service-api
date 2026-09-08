## Design document - Account Service Withdrawal API

## Context
account_service administra cuentas y sus balances

Necesitamos permitir que un cliente solicite el retiro de fondos de una cuenta

Debido a retries, timeouts y requests concurrents, una misma operación lógica
podría recibirse múltiples veces. El sistema debe evitar descontar el balance
más de una vez.

## Goals
El endpoint debe:
- permitir retirar fondos de una cuenta
- garantizar idempotencia
- manejar requests concurrentes de manera segura
- evitar balances negativos
- devolver consistentemente el resultado de un request repetido
- proporcionar errores claros al caller

## Non-goals
Para mantener el ejercicio acotado:
- amount será un entero
- no habrá múltiples monedas
- no habrá transferencia entre cuentas
- no implementaremos autenticación/autorización
- no implementamos integración con un payment provider externo

## API Contract

## Endpoint
http
POST /v1/accounts/{account_id}/withdrawals

## Request
JSON
{
    "idempotency_key": "1239867",
    "amount": 500
}

## Parameters

Campo                Tipo     Obligatorio    Descripción
account_id       UUID/Integer       Si       Cuenta sobre la que se hizo el retiro
idempotency_key     string          Si       Identificador idempotente proporcionado por el caller
amount              integer         Si       Cantidad a retirar

## Idempotency semantics
For a given account, a idempotency_key identifies exactly one logical withdrawal request
(account_id, idempotency_key) UNIQUE

Si tenemos:
POST  account=442 idempotency_key=A amount=500
POST  account=442 idempotency_key=A amount=700

Considerar conflicto de idempotencia y no procesarlo como otra operación.
Por ejemplo HTTP 409 Conflict

## Business Invariants
amount > 0: La cantidad a retirar siempre es positiva

balance >= amount: La cantidad a retirar siempre es menor o igual que el balance total

balance >= 0: Una cuenta no puede tener balance negativo

(account_id, idempotency_key): Una operación lógica de withdrawal solo puede descontar fondos como máximo una vez

balance = 500, Request A: withdraw 400, Request B: withdraw 400: Withdrawals concurrentes no pueden consumir los mismos fondos. Sólo uno puede ganar.

La validación del balance y su actualización debe de ser una operación atómica.

## Error semantincs
HTTP Responses

200 OK
JSON
{
    "result": "success",
    "balance_after_withdrawal": 1000
}

400 Bad Request
{
    "result": "bad_request",
    "message": "amount is required"
}

422 Unprocessable Content
{
    "result": "insufficient_funds",
    "current_balance": 300
}

404 Account not found

500 Internal server error
{
    "result": "internal server error"
}
Cualquier error mejor ponerlo en los logs en lugar de regresarlo al cliente <- Decisión discutible

##  Data model

Account
----------
account_id
balance

Withdrawal
withdrawal_id
account_id
idempotency_key
amount
resulting_balance
created_at

constraints (account_id, idempotency_key) UNIQUE

## Transaction boundary
create/find withdrawal
get balance
validate balance
decrement balance
mark withdrawal successful

Pregunta importante:
¿Cuáles de esas operaciones necesitan pertenecer a la misma transacción?

Ans: 
Yo preferiría tener atómicamente la parte de:
get balance hasta -> mark withdrawal successful 
Porque no nos gustaría que solamente el decremento y el mark withdrawal 
sean parte de la transacción. 
¿Podría darse el caso en que leamos un valor desactualizado por el replica lag
y sobre escribamos el balance que nosotros vemos?
¿Cómo evitamos ese problema?

## Failure scenarios
1. Duplicate sequential request
2. Duplicate concurrent request
3. Two different withdrawals competing for the same balance
4. Process crashes before modifying balance
5. Process crashes after modifying balance
6. Database transaction fails
7. Same idempotency key arrives the different amount

Preguntarse:
¿Qué observa el caller?
¿Qué queda persistido?
¿Es seguro hacer retry?

## Trade-offs
- Se utiliza pessimistic locking porque los casos de uso no involucran escenarios en donde tengamos cientos de requests concurrentes para hacer el retiro de fondos

## Open Questions

## Failure Modes Analysis
Account balance = 500

TX A                         TX B
----                         ----
read balance -> 500          read balance -> 500

500 >= 400 ✓                 500 >= 400 ✓

balance = 100                balance = 100

commit                       commit

Cada transacción hizo individualmente algo correcto,
pero globalmente acabamos de aceptar $800 de withdrawals teniendo $500

Necesitamos evitar que dos transacciones puedan tomar simultáneamente una decisión basada en el mismo balance viejo.

El request que llegue primero para cierto account_id, debe de hacer lock de ese registro.
Una herramienta típica es un row-level lock.

Para una cuenta determinada, solamente una transacción puede tomar decisiones sobre su balance a la vez.

Aparece un trade-off cuando usamos row level lock:
¿Qué pasa si una transacción mantiene ese lock durante mucho tiempo?
- contention
- latency
- timeout
- deadlocks
- mantener transacciones pequeñas

En este escenario, como todo ocurre a nivel de db, el mecanismo resulta más limpio

-> El chequeo del balance debe de suceder en la base de datos principal con la misma transacción que actualiza el balance (el writter)

Acerca de timestamps:
A created_at = 10:00:00.001
B created_at = 10:00:00.002

Esto no garantiza que A adquiriera primero el lock.
En sistemas concurrentes no debemos de confiar en timestamps para decidir quién ejecuta primero salvo que explícitamente estés construyendo un mecanismo de ordering.

En este ejercicio sólo necesitamos: Como máximo uno puede consumir los fondos disponibles.

Tenemos un account_service relativamente sencillo y los withdrawals de la misma cuenta probablemente no ocurren cientos de veces por segundo <- Observación clara para decidir por cuál solución irnos.

- Pessimistic locking
- Optimistic locking

¿Qué queremos?
- Que sea correcto
- Implementación fácil de entender
- Transacción corta
- Comportamiento predecible

En este escenario creo que es suficiente con que hagamos pessimistic locking, ya que no esperamos que hayan cientos de actualizaciones del balance en la cuenta del usuario pasando al mismo tiempo.
-> pessimistic row-level locking en este escenario

¿En qué momento exacto de la secuencia hay que adquirir el lock?
find/create Withdrawal
find Account
validate amount
validate balance
update Account
mark Withdrawal successful

Respuesta: Yo lo tomaría antes de encontrar la cuenta y lo dejaría hasta marcar el withdrawal como successful.

lock/find Account
      ↓
read authoritative balance
      ↓
validate balance
      ↓
update balance
      ↓
mark withdrawal
      ↓
commit
      ↓
lock released

En este escenario hay que validar el amount antes de entrar en el lock.
Así evitamos agregar tiempo a la transacción y bloquear la aplicación por más tiempo del debido.

El flujo final sería algo como:
validate request
       ↓
idempotency handling
       ↓
BEGIN TRANSACTION
       ↓
find Account WITH LOCK
       ↓
validate account state
       ↓
validate sufficient balance
       ↓
update balance
       ↓
mark withdrawal successful
       ↓
COMMIT

¿Qué pasa en el escenario en donde llegan 2 withdrawals concurrentes?
Request A                     Request B

account=1                     account=1
trace_id=X                    trace_id=X
amount=400                    amount=400

¿Qué queremos regresar si se crea primero A y luego encontramos que falla B porque ya existe B?
-> Probablemente queramos regresar el success de la primera operación porque ya intentamos la misma operación y fue exitosa.

