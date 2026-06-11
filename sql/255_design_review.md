# sql/255 — Design Review

Documento de arquitectura previo a la escritura del SQL de migración.
Basado en auditoría completa del codebase: schema, migraciones sql/252-254,
inventario de writers/readers y análisis de RLS.

---

## A. Estado actual exacto de los writers

### `groups.verification_status`

| Writer | Mecanismo | Rol requerido | Valores posibles | Caller |
|---|---|---|---|---|
| `sync_group_verification()` | Trigger SECURITY INVOKER | Quien dispara el INSERT en vr | pending / approved / rejected | Indirecto — cualquier INSERT/UPDATE en verification_requests |
| `admin_set_group_verified` RPC | SECURITY DEFINER | admin | approved / rejected | GroupsScreen.tsx:132 |
| `VerificationsScreen.tsx:130-138` | Direct UPDATE | admin (groups_admin_all) | approved / rejected | Solo admin |
| `VerificationScreen.tsx:325` | Direct UPDATE | group owner (groups_owner_all) | **pending únicamente** | Group owner |
| `submit_verification_session` (sql/185) | SECURITY DEFINER | owner | pending | **Sin caller — código muerto** |
| `admin_review_verification` (sql/185) | SECURITY DEFINER | admin | approved / rejected | **Sin caller — código muerto** |
| `groups_owner_all` (vulnerabilidad) | Direct UPDATE vía API | cualquier owner | cualquier valor | Requiere API directa |

### `groups.is_verified`

| Writer | Mecanismo | Valores | Caller |
|---|---|---|---|
| `sync_group_verification()` | Trigger SECURITY INVOKER | TRUE on approved, FALSE on rejected | Indirecto |
| `admin_set_group_verified` RPC | SECURITY DEFINER | TRUE / FALSE | GroupsScreen |
| `VerificationsScreen.tsx:131` | Direct UPDATE | TRUE | Admin only |
| `groups_owner_all` (vulnerabilidad) | Direct UPDATE vía API | cualquier valor | API directa |

### `groups.admin_verified`

| Writer | Mecanismo | Caller |
|---|---|---|
| `admin_set_group_verified` RPC | SECURITY DEFINER | GroupsScreen |
| `VerificationsScreen.tsx:132` | Direct UPDATE | Admin only |
| `groups_owner_all` (vulnerabilidad) | Direct UPDATE vía API | API directa |

### `profiles.verification_status`

| Writer | Mecanismo | Rol | Valores | Caller |
|---|---|---|---|---|
| `admin_set_profile_verified` RPC | SECURITY DEFINER | admin | approved / rejected | VerificationsScreen.tsx:173 |
| `ClientVerificationScreen.tsx:177` | Direct UPDATE | client owner (su propio profile) | **pending únicamente** | Client UI |

---

## B. Estado final propuesto post-sql/255

### Writers que sobreviven

| Writer | Observación |
|---|---|
| `admin_set_group_verified` RPC | Deprecated pero no eliminado. GroupsScreen lo sigue usando durante la transición. No rompe nada — SECURITY DEFINER bypassa REVOKE. Se eliminará en una migración posterior cuando GroupsScreen migre. |
| `admin_review_group_verification` RPC (nueva) | Reemplaza los direct UPDATEs de VerificationsScreen. Único path autorizado para approve/reject de grupos. |
| `submit_verification_request` RPC (nueva) | Reemplaza VerificationScreen:318+325. Único path para draft→pending. |
| `admin_set_profile_verified` RPC | Sin cambios. Sigue siendo el único path para approve/reject de profiles. |
| `ClientVerificationScreen direct UPDATE` | **Sin cambios en sql/255** si se elige Opción B (ver sección E). |

### Writers que desaparecen

| Writer | Qué lo reemplaza |
|---|---|
| `VerificationsScreen.tsx:130-138` direct UPDATE en groups | `admin_review_group_verification` RPC |
| `VerificationScreen.tsx:325` direct UPDATE en groups | `submit_verification_request` RPC |
| `groups_owner_all` UPDATE de is_verified/admin_verified/verification_status | Column-level REVOKE + GRANT parcial |

### Triggers que desaparecen

| Trigger | Función asociada | Razón |
|---|---|---|
| `sync_verification_status` | `sync_group_verification()` | Reemplazado por RPCs explícitas que gestionan el estado directamente |

### Funciones legacy que desaparecen

| Función | Razón |
|---|---|
| `sync_group_verification()` | Su trigger se elimina — la función queda huérfana |
| `submit_verification_session` (sql/185) | Código muerto confirmado — cero callers en frontend ni edge functions |
| `admin_review_verification` (sql/185) | Código muerto confirmado — cero callers |

### RPCs nuevas creadas

| Función | Propósito | Caller previsto |
|---|---|---|
| `start_group_verification(group_id)` | Crea draft o retorna draft existente (idempotente). Bloquea si hay pending activo o grupo ya verificado. | VerificationScreen |
| `update_verification_document(attempt_id, path)` | Guarda document_url en la fila draft. | VerificationScreen |
| `complete_verification_liveness(attempt_id)` | Marca liveness_verified=TRUE en la fila draft. | VerificationScreen |
| `submit_verification_request(attempt_id)` | Transiciona draft→pending. Valida documento y liveness. Actualiza groups.verification_status='pending'. | VerificationScreen |
| `admin_review_group_verification(attempt_id, approved, notes)` | Aprueba o rechaza. Actualiza vr + groups.is_verified + groups.admin_verified + groups.verification_status. | VerificationsScreen (nueva versión) |
| `admin_review_profile_verification(profile_id, approved, notes)` | Aprueba o rechaza perfiles (client/talent). Wrapper mejorado de admin_set_profile_verified. | VerificationsScreen (nueva versión) |
| `evaluate_group_verification(group_id)` | Combina compute_group_eligibility + compute_group_verification_state. Solo lectura. | VerificationScreen (carga inicial) |
| `evaluate_profile_verification(profile_id)` | Ídem para perfiles. | ClientVerificationScreen (carga inicial) |

### Cambios de permisos

| Cambio | Qué protege | Riesgo si se aplica antes de migrar frontend |
|---|---|---|
| `REVOKE UPDATE ON groups FROM authenticated` | groups.is_verified, admin_verified, verification_status | ALTO — rompe VerificationsScreen y VerificationScreen:325 |
| `GRANT UPDATE(name, genre, description, city, state, profile_image, promo_video, is_active, price_from, bid_amount, lat, lng, service_cities, ...)` | Preserva writes legítimos del owner | Ver checklist de columnas en sección F |
| Partial unique index `WHERE status='pending'` | Invariante: máximo 1 pending por grupo | Bajo — UI oculta submit cuando ya hay pending |
| Partial unique index `WHERE status='draft'` | Invariante: máximo 1 draft por grupo | Bajo — start_group_verification es idempotente |

---

## C. Matriz de compatibilidad por pantalla

### VerificationScreen — group owner

| Aspecto | Estado actual | Estado post-sql/255 | Riesgo | Mitigación |
|---|---|---|---|---|
| Envío de solicitud | INSERT vr (upsert status=pending) + UPDATE groups.verification_status='pending' | `submit_verification_request(attempt_id)` RPC | **ALTO** si deploy no es atómico | Frontend migrado antes de aplicar REVOKE |
| Subida de documento | upsert con status='draft' (silently failed antes de sql/253; ahora crea fila draft) | `update_verification_document(attempt_id, path)` | BAJO | La nueva RPC persiste correctamente |
| Liveness | upsert con liveness_verified=true (crea nueva fila draft) | `complete_verification_liveness(attempt_id)` | BAJO | La nueva RPC actualiza la fila correcta |
| Lectura de estado | `group.verification_status` + `req?.liveness_verified` + `req?.document_url` | `evaluate_group_verification(group_id)` | NINGUNO — campos siguen existiendo | Lectura directa sigue funcionando en transición |
| Protección post-REVOKE | Línea 325 escribe groups directamente | Esa escritura será bloqueada | **ALTO** | Eliminar línea 325 antes del REVOKE |

### VerificationsScreen — admin (tab Grupos)

| Aspecto | Estado actual | Estado post-sql/255 | Riesgo | Mitigación |
|---|---|---|---|---|
| Aprobar grupo | UPDATE vr.status + UPDATE groups.is_verified/admin_verified/verification_status | `admin_review_group_verification(attempt_id, true, notes)` | **ALTO** si REVOKE antes de migración | Atomic deploy |
| Rechazar grupo | UPDATE vr.status + UPDATE groups.verification_status | `admin_review_group_verification(attempt_id, false, notes)` | **ALTO** si REVOKE antes de migración | Atomic deploy |
| Aprobar client/talent | `admin_set_profile_verified` RPC | `admin_review_profile_verification` RPC (wrapper mejorado) | BAJO — ambas producen el mismo resultado | Sin cambio urgente |
| Lectura de solicitudes pendientes | `SELECT * FROM verification_requests ORDER BY submitted_at DESC` | Misma query — misma tabla | NINGUNO | — |
| Mostrar filas draft en la cola | Nunca mostraba drafts (no existían antes de sql/253) | Ahora existen drafts — fetchGroups sin filtro los incluiría | BAJO | Agregar `.neq('status', 'draft')` al fetchGroups |

### GroupsScreen — admin

| Aspecto | Estado actual | Estado post-sql/255 | Riesgo | Mitigación |
|---|---|---|---|---|
| Verificar/desverificar grupo | `admin_set_group_verified` RPC | Misma RPC — **no se elimina en sql/255** | NINGUNO | admin_set_group_verified es SECURITY DEFINER, bypassa el nuevo REVOKE |
| Leer campos de verificación | SELECT groups (is_verified, admin_verified, verification_status) | Sin cambios | NINGUNO | — |

### ClientVerificationScreen — client

| Aspecto | Estado actual | Estado post-sql/255 (Opción B) | Riesgo | Mitigación |
|---|---|---|---|---|
| Actualizar info del perfil | UPDATE profiles (full_name, phone, city, state) | Sin cambios | NINGUNO | — |
| Enviar solicitud | UPDATE profiles.verification_status='pending' directo | **Sin cambios si se elige Opción B** | NINGUNO con Opción B | Protección de profiles.verification_status se pospone a sql/256 |
| Lectura del estado | `profile.verification_status` | Sin cambios | NINGUNO | — |

### DashboardScreen — admin

| Aspecto | Estado actual | Estado post-sql/255 | Riesgo |
|---|---|---|---|
| Widget pendientes | `SELECT WHERE status='pending' LIMIT 5` | Misma query — índice parcial acelera esta consulta | NINGUNO |

### HomeScreen — client

| Aspecto | Estado actual | Estado post-sql/255 | Riesgo |
|---|---|---|---|
| Badge verificado | Lee `groups.is_verified` via `get_groups_ranked_by_city` | Sin cambios — campo sigue existiendo | NINGUNO |

### GroupDetailScreen — client

| Aspecto | Estado actual | Estado post-sql/255 | Riesgo |
|---|---|---|---|
| Badge y mensaje de confianza | Lee `groups.is_verified` | Sin cambios | NINGUNO |

---

## D. Plan de despliegue exacto

### Fase 1 — SQL puro, independiente, desplegable en cualquier momento

Puede aplicarse sin cambios de frontend. No afecta flujos en producción.

- Deduplicación de filas pending y draft
- Creación de índices parciales `uidx_vr_group_pending` y `uidx_vr_group_draft`
- Creación de todas las RPCs nuevas (`start_group_verification`, `update_verification_document`, `complete_verification_liveness`, `submit_verification_request`, `admin_review_group_verification`, `admin_review_profile_verification`, `evaluate_group_verification`, `evaluate_profile_verification`)
- DROP de funciones de código muerto: `submit_verification_session`, `admin_review_verification`

**Por qué es seguro en Fase 1:**
- Los nuevos índices no rompen el flujo actual. El UI oculta el botón de submit cuando ya hay un pending activo, por lo que la unicidad ya estaba implícita en el diseño.
- Las nuevas RPCs coexisten con las funciones legacy sin conflicto.
- El DROP de funciones sin callers no afecta a nadie.

### Fase 2 — Frontend (prerequisito de Fase 3)

Debe desplegarse antes de aplicar el REVOKE y el DROP del trigger.

- `VerificationScreen`: reemplazar upsert + UPDATE directo con `start_group_verification`, `update_verification_document`, `complete_verification_liveness`, `submit_verification_request`
- `VerificationsScreen` (tab grupos): reemplazar direct UPDATE en groups con `admin_review_group_verification`
- `VerificationsScreen` (fetchGroups): añadir filtro `.neq('status', 'draft')` para excluir drafts de la cola de revisión
- Verificar que VerificationScreen no muestre regresiones con el nuevo flujo

### Fase 3 — SQL hardening (atómico con Fase 2 o inmediatamente después)

No aplicar hasta confirmar que Fase 2 está en producción y funcionando correctamente.

- `DROP TRIGGER sync_verification_status ON verification_requests`
- `DROP FUNCTION sync_group_verification()`
- `REVOKE UPDATE ON groups FROM authenticated`
- `GRANT UPDATE(columnas_seguras) ON groups TO authenticated`

**Restricción dura:** Fase 3 nunca antes de Fase 2. Aplicarlas en la misma ventana de despliegue o con intervalo máximo de minutos, no horas.

---

## E. Decisión sobre `profiles.verification_status`

### Opción A — Incluir protección de profiles en sql/255

**Qué implica:**
- Agregar column-level REVOKE/GRANT en profiles
- Migrar `ClientVerificationScreen.tsx:177` a usar `admin_review_profile_verification` RPC
- Desplegar frontend de ClientVerificationScreen en la misma ventana que la protección SQL

**Ventajas:**
- Cierra todos los direct UPDATE de campos de verificación en una sola migración
- Arquitectura final más limpia al salir de sql/255

**Riesgos:**
- Aumenta el alcance del frontend a migrar en Fase 2
- ClientVerificationScreen.tsx maneja más estado que VerificationScreen — mayor superficie de regresión
- La protección de profiles.verification_status es menos urgente que la de groups (ver análisis de criticidad abajo)

**Criticidad del riesgo actual:**
`ClientVerificationScreen` solo puede escribir `verification_status='pending'` (propio perfil). Esto representa el riesgo de que un cliente solicite revisión sin haber completado sus datos — administrable, no crítico. No existe equivalente a `sync_group_verification` que convierta ese 'pending' en 'approved' automáticamente.

### Opción B — Dejar profiles para sql/256

**Qué implica:**
- `profiles.verification_status` queda sin protección de columna en sql/255
- `ClientVerificationScreen` sigue usando direct UPDATE ('pending' únicamente)
- `admin_review_profile_verification` RPC se crea en Fase 1 pero ClientVerificationScreen no migra todavía

**Ventajas:**
- Reduce alcance de sql/255 significativamente
- Permite probar el núcleo de la migración (grupos) antes de extender a perfiles
- La vulnerabilidad residual en profiles es de baja criticidad

**Riesgos:**
- profiles.verification_status sigue siendo escribible directamente por el cliente hasta sql/256
- Deuda técnica documentada y acotada

### Recomendación formal: **Opción B**

El riesgo de incluir profiles en sql/255 es mayor que el riesgo de dejarlo para sql/256. La vulnerabilidad en grupos (`groups_owner_all` permite `is_verified=true`) es visualmente crítica — afecta el badge público que los clientes ven. La vulnerabilidad en profiles solo permite que un cliente ponga su propia solicitud en 'pending', lo cual no engaña a nadie directamente y el admin puede rechazar. Mantener sql/255 enfocado en grupos reduce la superficie de error del despliegue más riesgoso del proyecto hasta ahora.

---

## F. Checklist GO/NO-GO antes de ejecutar sql/255

### Prerrequisitos técnicos

- [ ] **Preflight completo:** secciones 4-9 de `255_preflight.sql` revisadas y sin bloqueantes
- [ ] **Lista de columnas del GRANT verificada:** ejecutar `SELECT column_name FROM information_schema.columns WHERE table_name='groups' ORDER BY column_name` y confirmar que la lista de columnas seguras en el GRANT es exhaustiva. Columnas conocidas como legítimas: name, genre, description, city, state, profile_image, promo_video, is_active, price_from, bid_amount, lat, lng, service_cities — verificar si existen otras que el frontend escriba
- [ ] **Rollback preparado y revisado** antes de iniciar el despliegue

### Prerrequisitos de frontend (antes de Fase 3)

- [ ] **VerificationScreen migrado:** el grupo owner puede completar el flujo KYC completo con las RPCs nuevas (start → update_doc → complete_liveness → submit)
- [ ] **VerificationsScreen migrado:** admin puede aprobar y rechazar grupos usando `admin_review_group_verification`
- [ ] **fetchGroups filtrado:** la cola de admin no muestra filas draft
- [ ] **Prueba end-to-end en staging:** un grupo completa verificación → admin aprueba → badge aparece en HomeScreen

### Prerrequisitos de despliegue

- [ ] **Ventana de mantenimiento coordinada:** Fase 2 (frontend) y Fase 3 (SQL hardening) desplegadas en la misma ventana o con intervalo < 15 minutos
- [ ] **GroupsScreen funcional post-REVOKE:** verificar que `admin_set_group_verified` sigue funcionando (es SECURITY DEFINER, bypassa el GRANT)
- [ ] **DashboardScreen widget verificado:** el conteo de pending sigue siendo correcto después de la deduplicación
- [ ] **Sin sesiones activas de grupos durante Fase 3:** idealmente aplicar el REVOKE en horario de baja actividad para evitar errores visibles durante la transición

### Criterios de GO

Todos los ítems anteriores marcados ✅ → **GO**

Cualquier ítem bloqueante sin resolver → **NO GO** hasta resolver
