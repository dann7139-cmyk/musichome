# ✅ Checklist de auditoría — Beta cerrada Daricefy

> Fecha de inicio: 2026-07-10
> Regla: cada punto se marca solo cuando se probó **en el teléfono real** (no solo en código).
> Cuando TODO pase → commit estable + tag `v0.9.0-beta`.

Cómo marcar: `[ ]` pendiente · `[x]` pasó · `[!]` falló (anotar abajo en "Bugs encontrados").

---

## 1. Explorador normal (cliente)

- [ ] El home carga sin spinner infinito con perfil normal (state = Jalisco).
- [ ] Solo aparecen grupos del estado del cliente (+ nacionales con state NULL).
- [ ] Buscador: buscar por nombre filtra bien; la X limpia y regresa a la vista normal.
- [ ] Botón de ubicación (GPS): activa "cerca de ti" y se puede quitar con la X.
- [ ] Categorías: elegir una filtra; quitarla regresa todo.
- [ ] Tarjetas ⚡ Express y 🌎 Otra ciudad: se ven parejas, títulos a la izquierda, chip/emoji a la derecha, CTA "Solicitar ›" / "Explorar ›" visible sin robar espacio.
- [ ] Al presionar cada tarjeta hay feedback visual (se atenúa) y navega bien.
- [ ] Pull-to-refresh funciona y no duplica secciones.
- [ ] Cliente viajando (state del perfil ≠ GPS): aparece LocationBanner y ambos botones funcionan.

## 2. Express

- [ ] "Express → Solicitar" abre GuidedRequest.
- [ ] Se crea la solicitud y aparece el banner "📡 tu solicitud" en el home.
- [ ] El grupo recibe la solicitud y puede mandar propuesta.
- [ ] Cliente ve propuestas (carrusel de propuestas) y puede aceptar.
- [ ] Flujo completo hasta pago sin pantallas en blanco.
- [ ] La solicitud expira/se cierra correctamente (no queda "abierta" para siempre).

## 3. Otra ciudad (modo explorar/regalo)

- [ ] "Otra ciudad → Explorar" abre el selector país/estado.
- [ ] Pestañas México/Estados Unidos muestran sus estados (32 MX / 50 US).
- [ ] Elegir estado → banner "Explorando {estado}" y SOLO grupos de ese estado.
- [ ] Estado sin grupos → lista vacía (NO muestra grupos de otros estados).
- [ ] "Cambiar" reabre el selector; la X sale del modo y regresa a los grupos del cliente.
- [ ] Entrar/salir del modo NO cambia la ciudad/estado guardados del perfil.
- [ ] En modo explorar, abrir grupo → cotizar funciona normal (flujo programada).

## 4. Caja de regalo 🎁

- [ ] En QuoteForm aparece el switch "¿Es un regalo?" apagado por defecto.
- [ ] Sin activarlo: todo el flujo es idéntico a antes (regresión cero).
- [ ] Activado: pide nombre del destinatario (obligatorio), mensaje y contacto (opcionales).
- [ ] Validación: no deja enviar sin nombre del destinatario.
- [ ] El teclado no tapa los campos del regalo (scroll funciona).
- [ ] La cotización guarda is_gift + datos; el grupo la ve normal (sin datos sensibles raros).
- [ ] Al aceptar y pagar: la reserva hereda is_gift + destinatario + mensaje.
- [ ] Ticket de regalo muestra: De (comprador), Para (destinatario), Mensaje, Grupo, fecha, hora, 📍 ciudad, folio y código.
- [ ] La fila 📍 SOLO aparece en tickets de regalo; el ticket normal está idéntico a antes.
- [ ] Descargar/compartir el ticket como imagen funciona (WhatsApp).
- [ ] Reserva normal (no regalo) → ticket normal sin nada de regalo.

## 5. Carruseles Destacados / Recomendados / Populares

- [ ] Se ven los 3 en UNA hilera con chips degradados (dorado/verde/blanco).
- [ ] "Recomendados" se lee completa (no cortada) en el teléfono real.
- [ ] Cada baraja: 1 foto al frente OPACA + 2 atrás tenues, sin invadir la columna vecina.
- [ ] Avanzan solas (~2.2s) y se pausan 6s al tocarlas.
- [ ] Deslizar con el dedo: derecha regresa, izquierda avanza.
- [ ] Flechitas ‹ › visibles y funcionan al tocarlas.
- [ ] Tocar la foto del frente abre el perfil del grupo correcto.
- [ ] Badges: DEST (dorado) y RECO (verde) solo en pagados; Populares solo 📈 sin fondo.
- [ ] Si solo hay 1 o 2 secciones con grupos, se reparten el ancho (más grandes) sin romperse.
- [ ] Con 1 solo grupo en una sección: no salen flechitas ni tarjetas de atrás.
- [ ] En modo "Otra ciudad": los carruseles muestran grupos del estado elegido.
- [ ] Verificar reparto: con datos reales de patrocinio los pagados van a su sección; sin datos, se reparten por rating.

## 6. Anuncios (banner)

- [ ] Sin anuncios activos en DB → NO aparece ningún banner (ni foto fantasma).
- [ ] Con anuncio de imagen: se ve compacto (132px), título/botón chicos y legibles.
- [ ] Con anuncio de video: reproduce, botón 🔊/🔇 funciona.
- [ ] Salir del explorador (otra pestaña/pantalla) → el sonido se corta.
- [ ] Volver al explorador → el video suena de nuevo (si no lo silenciaste tú).
- [ ] Varios anuncios: carrusel avanza, dots funcionan.
- [ ] Tocar el anuncio navega a donde debe (grupo o link).
- [ ] Chip "ANUNCIO" visible siempre.
- [ ] SQL: `SELECT * FROM promotions WHERE is_active = true;` → 0 filas (o solo las deseadas).

## 7. Filtros por estado

- [ ] Cliente Jalisco ve solo grupos Jalisco + nacionales.
- [ ] Grupos con state NULL aparecen en todos los estados (decidir si eso es lo que quieres para beta).
- [ ] SQL revisión de formatos mezclados:
  ```sql
  SELECT DISTINCT state FROM groups ORDER BY 1;
  SELECT DISTINCT state FROM profiles WHERE state IS NOT NULL ORDER BY 1;
  ```
  → NO debe haber abreviaturas ('jal.', 'CDMX' vs 'Ciudad de México', etc.). Corregir datos si aparecen.
- [ ] Registrar un usuario nuevo con GPS → su state se guarda con el nombre completo del estado.

## 8. Pago con tarjeta (Conekta)

- [ ] Checkout muestra métodos: Tarjeta / SPEI / Efectivo / Meses. Sin logos ni menciones de Conekta/Stripe.
- [x] Tarjeta de prueba 4242… → pago exitoso, pantalla de éxito, reserva en 'paid'. — validado 2026-07-10 (reserva b1d118ae, provider=conekta)
- [ ] El grupo recibe notificación de pago.
- [x] Wallet del grupo: pending_balance sube EXACTAMENTE base_price (total/1.20). — $10,800 → $9,000.00 exactos (2026-07-10)
- [x] NO aparece msi_months/msi_fee en pagos de tarjeta normal (bug del $540 fantasma). — CONFIRMADO MUERTO 2026-07-10: reserva sembrada con msi 3/$540, pagada con tarjeta Conekta → msi_months=NULL, msi_fee_amount=0, plataforma registró "MSI $0", grupo recibió $9,000 exactos.
- [ ] Tarjeta rechazada (usar tarjeta de fallo de Conekta) → mensaje claro, la reserva NO queda pagada, se puede reintentar.
- [x] Doble webhook / doble tap en pagar → no acredita doble (idempotencia). — VALIDADO 2026-07-10: 4 cargos SPEI pagados en Conekta para la misma reserva → 1 solo abono al wallet; pending_balance = 3×$9,000 exactos tras 3 reservas pagadas.

## 9. SPEI con descuento

- [x] Elegir SPEI muestra el descuento de $100 en el resumen. — cargo real $10,700 vs $10,800 confirmado en panel Conekta (2026-07-10)
- [x] Se genera la CLABE/referencia y se muestra al cliente. — corregido con pantalla in-app + copiar (bug #2); falta confirmar visual en teléfono
- [x] Simular/hacer la transferencia sandbox → webhook confirma → reserva 'paid'. — validado 2026-07-10 (reserva 03b3820a)
- [x] El grupo cobra su base COMPLETA (el descuento sale del margen de la plataforma, no del grupo). — $9,000 exactos (2026-07-10)
- [ ] Pago SPEI no realizado → la reserva queda pendiente y expira bien (no se queda colgada como pagada).

## 10. Efectivo

- [x] Elegir Efectivo genera referencia (OXXO/paycash) visible y copiable. — pantalla in-app validada en teléfono 2026-07-10
- [x] Pago sandbox confirmado → webhook → reserva 'paid' + wallet correcto. — cargo $10,800 completo (sin descuento SPEI ✓), grupo $9,000; pending_balance=4×$9,000=$36,000 exactos (2026-07-10)
- [ ] Referencia no pagada → expira sin marcar pagada.

## 11. Meses (Stripe MSI)

- [x] Elegir Meses abre PaymentSheet de Stripe (no Conekta). — validado 2026-07-10
- [x] MSI 3/6/… disponibles con tarjeta de crédito de prueba. — 3 MSI validado 2026-07-10
- [ ] El recargo por meses se muestra al cliente ANTES de pagar.
- [x] Al pagar: reserva 'paid', el grupo recibe base_price (sin el recargo MSI). — $10,800 → grupo $9,000 exactos; plataforma $1,800+$540−$411.24 fee = $1,928.76, cuadra al centavo (reserva de71a854, 2026-07-10)
- [ ] El banner "Hasta 12 cuotas" del home sigue apareciendo 4s y desaparece.

## 12. Reembolsos

- [x] Cancelación por cliente dentro de política → reembolso procesado. — VALIDADO 2026-07-11: tarjeta = automático (Conekta "Devolución parcial" $8,100 de $10,800, tier partial_25); SPEI/efectivo = cola manual con CLABE validada, comprobante y notificación (flujo completo probado en teléfono)
- [x] Reversión de wallet exacta: pending −$9,000, compensación grupo +$1,890 (17.5%), ajuste plataforma −$990. — validado en 2 cancelaciones (efectivo b93a8, tarjeta b1d1)
- [x] Reembolso doble (re-ejecutar) → NO resta dos veces. — settle idempotente (already_settled) + Idempotency-Key
- [ ] Cancelación por grupo → strike automático + reembolso al cliente. (C3 pendiente — el grupo aún no puede cancelar desde su app)
- [x] Reserva reembolsada NO aparece activa ni genera liberación. — ciclo de vida: visible con "reembolso en camino" → "enviado" 7 días → se oculta; triple candado C0/451/424 impide liberar
- [x] payout_status termina en 'refunded' y NO se libera después. — bugs #465 (cancelled_by check) encontrado y corregido en prueba real

## 13. Wallet, GPS, liberación 50/50 y retiro

- [ ] Pago confirmado → payout_status='held', pending_balance= base_price.
- [ ] GPS llegada: a >250m NO deja marcar llegada; a <200m sí (candado server-side sql/424).
- [ ] Llegada verificada → se libera el 50% (verificar montos exactos en wallet_transactions).
- [ ] Evento termina → 12h después el cron libera el 50% restante (o probar con admin_release_reservation).
- [ ] available_balance = suma de liberados; pending = lo retenido. Correr `check_wallet_integrity` → 0 inconsistencias.
- [ ] Disputa abierta → BLOQUEA la liberación.
- [ ] Retiro: request_withdrawal descuenta de group_wallets (fix sql/460), estado pendiente → admin aprueba → estado pagado.
- [ ] Retiro por más del disponible → rechazado con mensaje claro.
- [ ] Grupo NO ve comisión/desglose de la plataforma en ninguna pantalla (solo "Tu ganancia"); cliente solo ve "Total a pagar".

## 14. Datos de prueba (limpiar ANTES de la beta)

- [ ] `DELETE FROM groups WHERE name LIKE '🧪%';` (grupos test viejos).
- [ ] Demos de Jalisco: DECIDIDO (2026-07-10) → se quitan antes de la beta porque pueden confundirse con grupos reales. Correr `sql/463_remove_demo_groups_before_beta.sql` JUSTO antes de la beta (incluye guard de reservas pagadas). Mientras, se quedan para pruebas sandbox.
- [ ] Fotos picsum.photos: ningún grupo real debe quedar con foto de picsum.
- [ ] Cuentas de prueba (Lala, Derek, etc.): limpiar reservas/pagos de prueba o marcar como test.
- [ ] `SELECT * FROM promotions;` → limpiar promos legacy.
- [ ] Revisar advertisements/bid_orders/recommendation_orders de prueba.
- [ ] Verificar que Conekta/Stripe estén en las llaves CORRECTAS para beta (¿sandbox o producción?) — decisión explícita.

## 15. Textos y precios

- [ ] Cero menciones de "comisión" en UI (siempre "Tarifa de servicio" para cliente / "Tu ganancia" para grupo).
- [ ] Cero menciones visibles de Conekta/Stripe/MercadoPago en pantallas.
- [ ] Revisar ortografía de pantallas nuevas: tarjetas Express/Otra ciudad, selector de estados, switch de regalo, ticket de regalo, chips de carruseles.
- [ ] Precios siempre con formato $X,XXX MXN consistente (misma función de formato en todas las pantallas).
- [ ] Totales cuadran en: BookingScreen → checkout → ticket → wallet grupo (mismo número en los 4).
- [ ] SPEI: el descuento se refleja en el total mostrado Y en lo cobrado real.
- [ ] Textos en inglés colados (i18n): pasar por las pantallas principales en español y cazar strings sin traducir.

## 16. Pantallas pequeñas (probar en un teléfono chico o reduciendo)

- [ ] Tarjetas Express/Otra ciudad: textos no se encimen, CTA visible.
- [ ] Carruseles: 3 columnas caben, "Recomendados" completa, flechitas no encimadas.
- [ ] Banner de anuncio: botón y título legibles a 132px.
- [ ] QuoteForm con teclado abierto: todos los campos alcanzables (personas, festejado, regalo).
- [ ] Ticket de regalo: todo el contenido cabe y la imagen exportada sale completa.
- [ ] Selector de estados: lista scrolleable, no cortada por el notch/navegación.
- [ ] Modales (citySel, etc.) cierran con el backdrop y el botón X.

## 17. Errores de navegación

- [ ] Botón atrás (hardware Android) en: checkout, ticket, selector estados, GuidedRequest → nunca pantalla en blanco ni crash.
- [ ] Ir atrás DURANTE un pago → la reserva no queda en estado imposible; se puede reintentar.
- [ ] Deep de flujo: Home → Otra ciudad → Grupo → Cotizar → atrás atrás atrás → Home sano (giftMode consistente).
- [ ] Cerrar sesión y entrar con otro rol (cliente → grupo) → no queda estado del rol anterior.
- [ ] Matar la app a media pantalla de pago y reabrir → estado coherente.
- [ ] Notificación push → tocar → navega a la pantalla correcta con datos cargados.

## 18. Logs y fallos silenciosos

- [x] Quitado console.log de BANNER ADS en HomeScreen (2026-07-10).
- [ ] Barrer console.log restantes con datos sensibles (CitySelectScreen 12, AuthContext 10, EventTimerScreen 8 — revisar que ninguno imprima tokens/IDs de pago).
- [ ] Revisar catch vacíos en flujos de dinero: ningún error de pago/webhook debe tragarse sin log en payment_event_logs.
- [ ] `SELECT * FROM payment_event_logs WHERE is_mismatch = true;` → investigar cada fila.
- [ ] Edge Functions: revisar logs de create-conekta-order / webhooks en Supabase → sin errores 500 recurrentes.
- [x] ⚠️ PENDIENTE CONOCIDO: redeploy de create-conekta-order (limpieza MSI + método) — desplegado 2026-07-10.
- [ ] ⚠️ PENDIENTE CONOCIDO: redeploy de process-refund si se cambió.
- [ ] Probar la app con internet lento/apagado a media carga → mensajes de error, no cuelgues.

---

## 🐛 Bugs encontrados

| # | Pantalla/flujo | Qué pasó | Gravedad (bloquea beta S/N) | Estado |
|---|----------------|----------|------------------------------|--------|
| 1 | Contabilidad plataforma (RPC confirm_full_payment) | En pagos Conekta, el platform_income descuenta y etiqueta la tarifa del procesador con la fórmula de Stripe (3.6%+$3): "− Stripe $391.80" en un pago Conekta. No afecta dinero de grupo ni cliente; solo la métrica interna de ganancia neta. | N | Pendiente — corregir fórmula/etiqueta por proveedor |
| 2 | Checkout SPEI/Efectivo | La página hosted de Conekta muestra la CLABE/referencia unos segundos y redirige a success_url (daricefy.com, dominio inexistente) → el cliente la pierde y no puede transferir. | S | CORREGIDO Y VALIDADO 2026-07-10 en teléfono (pantalla fija + botón copiar). Mejora futura: persistir la referencia y mostrarla en "Mis Eventos" (hoy, si sale de la pantalla, regenera una nueva desde "Pago pendiente" — ligado al bug #3). |
| 3 | Órdenes Conekta duplicadas | Cada reintento de pago crea una orden nueva y las referencias SPEI anteriores siguen vivas. Si el cliente paga una referencia vieja de una reserva ya pagada, el dinero llega pero el webhook lo ignora (no acredita, no reembolsa). El wallet queda bien (idempotente ✓) pero el cliente pagaría doble. | N (fix antes de producción) | Pendiente — al crear orden nueva, expirar/cancelar órdenes previas de la misma reserva (o expires_at corto), y en el webhook auto-reembolsar cargos de reservas ya pagadas. |
| 4 | Ledger plataforma (SPEI) | El platform_income no resta el descuento SPEI: registra "Comisión $1800" cuando realmente entraron $1,700 ($10,700 cobrados − $9,000 grupo). Junto con el bug #1 (fee Stripe hardcodeada), la métrica interna de ganancia neta queda desviada. Dinero real de grupo/cliente correcto. | N | Pendiente — RPC debe calcular sobre monto realmente cobrado y fee del proveedor real. |
| 5 | Cotización (UX) | La forma de pago se elegía DOS veces: selector de meses en la cotización (sin efecto real) y luego el checkout completo. | N | CORREGIDO Y VALIDADO 2026-07-10: selector eliminado de ClientQuoteDetailScreen; el checkout es el único lugar donde se elige método. |
| 6 | Reembolso de pagos SPEI/Efectivo (Conekta) | process-refund llama POST /orders/{id}/refunds — Conekta solo reembolsa así pagos con TARJETA. Un cliente que pagó por SPEI/efectivo y cancela probablemente recibirá error 502 y quedará atorado en "Reintentar" sin salida. | S (para beta si se prueban cancelaciones SPEI/cash) | Pendiente — fallback: liquidar en DB + marcar reembolso manual + notificar a admin (transferencia) y al cliente "te contactaremos". Confirmar comportamiento real en sandbox primero. |
| 7 | Cancelación: inconsistencias menores | (a) settle_cancellation deja payment_status='paid' en canceladas (solo status/payout cambian); (b) fallback de base usa 0.9 (modelo 10% viejo) si base_price es NULL; (c) talentos del grupo NO reciben notificación al cancelar una RESERVA (solo en el camino de cotización); (d) refund de admin sobre payout 'blocked' post-half_released revertiría base completa (caso borde admin-only). | N | Pendiente — limpiar en el lote C3/C6. |

---

## 🏁 Cierre

- [ ] Todos los puntos S (bloqueantes) resueltos.
- [ ] Commit estable de la auditoría.
- [ ] Tag: `git tag v0.9.0-beta`.
- [ ] Lista de 3–5 usuarios reales para la beta cerrada + cómo recibir su feedback (grupo de WhatsApp).
