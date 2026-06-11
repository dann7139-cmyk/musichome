# Daricefy — Descripción Visual de Pantallas + Sugerencias de Diseño

---

## PANTALLA: LoginScreen

### Elementos (de arriba a abajo)
1. Fondo `#040404` con partículas animadas flotando
2. Gradiente verde sutil en esquina superior izquierda
3. Nombre/logo de la app (texto Syne ExtraBold, blanco, centrado)
4. Campo email — ícono Mail, borde `#1C1C1C`, fondo `#0e0e0e`, placeholder gris
5. Campo contraseña — ícono Lock, mismo estilo
6. Botón "Iniciar sesión" — verde `#00E676`, texto negro, border-radius 14
7. Link "¿No tienes cuenta? Regístrate" — texto gris

### Animaciones
- Logo hace fade+slide desde arriba (600ms, delay 150ms)
- Formulario hace slide desde abajo (500ms, delay 400ms)

### Sugerencias de diseño
- **PROBLEMA**: El logo es solo texto, sin ícono — le falta identidad visual
- El botón podría tener ícono de flecha o candado abierto para más claridad
- Los campos no tienen feedback visual cuando están enfocados (focus ring)
- Agregar "¿Olvidaste tu contraseña?" link debajo del botón

---

## PANTALLA: HomeScreen (Dashboard del Cliente)

### Elementos (de arriba a abajo)
1. SafeAreaView, fondo `#040404`, partículas animadas de fondo
2. Header:
   - Izquierda: avatar circular del usuario (40px) + "Hola, [nombre]" (Syne, blanco)
   - Derecha: botón de notificaciones (badge rojo con count si hay no leídas)
3. Buscador — TextInput con ícono Search, borde verde cuando tiene texto
4. Banner de anuncio pagado — imagen full-width, 200px alto, border-radius 20
5. Sección "⚡ Solicitar ahora":
   - Botón principal verde "Solicitar grupo ahora" (ancho completo)
   - Botón secundario "Solicitud guiada" (borde verde)
6. Título "Grupos recomendados"
7. Carrusel horizontal de grupos — tarjetas de 23% del ancho con scroll horizontal
   - Cada tarjeta: imagen cuadrada + nombre + rating
8. Título "Cerca de ti" + subtítulo ciudad detectada
9. Lista vertical de grupos:
   - Cada card: imagen 80×80 redondeada (izq) + nombre + género + estrellas + "desde $X,XXX" (der)

### Colores de elementos
- Header background: transparente (fondo negro se ve)
- Buscador: `#0e0e0e` fondo, borde `#1C1C1C` → `#00E676` activo
- Botón principal: `#00E676` fondo, texto negro
- Botón secundario: borde `#00E676`, fondo transparente, texto verde
- Cards de grupos: `#0e0e0e` fondo, borde `#1C1C1C`

### Sugerencias de diseño
- **PROBLEMA ALTO**: Las tarjetas del carrusel son demasiado pequeñas (23% = ~85px en iPhone). Son difíciles de leer y tocar
  - Sugerencia: aumentar a 35-40% del ancho (~130-150px)
- **PROBLEMA MEDIO**: La sección "Solicitar ahora" no es suficientemente prominente — es el CTA principal de la app
  - Sugerencia: darle un card con gradiente verde sutil de fondo para que destaque
- Las cards de grupos en la lista vertical son compactas — podrían tener un poco más de padding
- Agregar separadores visuales más claros entre secciones (no solo espacio)

---

## PANTALLA: GuidedRequestScreen (Express — 3 pasos)

### Paso 1 — Tipo de evento
- Fondo con gradiente verde sutil en esquina
- Header: flecha atrás + título "Solicitar grupo"
- Grid 2×4 de tarjetas:
  - Cada tarjeta: emoji grande (36px) + etiqueta (DMSans 14px)
  - Inactiva: fondo `#0e0e0e`, borde `#1C1C1C`
  - Activa: fondo `rgba(0,230,118,0.08)`, borde `#00E676`
- Al tocar → avanza automáticamente al paso 2

### Paso 2 — Detalles
- 3 puntos de progreso arriba (8px, el actual verde más ancho 24px)
- Título "Detalles del evento" (Syne 22px, centrado)
- Chips de géneros con emoji (wrap, 14 opciones)
- Card de ubicación GPS (verde translúcido) con botón "Editar"
- Chip de hora (abre modal de rueda)
- Input de invitados (numérico)
- Chips de duración (3h, 4h, 5h, 6h, 8h+)
- Botón "Continuar →" — verde sólido cuando válido, gris con borde cuando no

### Paso 3 — Lugar
- Botón mapa "📍 Seleccionar en el mapa" (borde verde, fondo verde translúcido)
- Una vez seleccionado: card verde con dirección confirmada + "Cambiar"
- Chips: techado (3 opciones)
- Grid 2×2: tamaño del lugar
- Chips: sonido (3 opciones)
- TextArea: comentarios (500 chars)
- Card de resumen (borde verde translúcido, líneas de texto)
- Botón "⚡ Enviar solicitud a grupos" — verde grande, padding 16
- Texto hint gris debajo

### Sugerencias de diseño
- **PROBLEMA MEDIO**: Los dots de progreso son muy pequeños (8px) — difícil saber en qué paso se está
  - Sugerencia: reemplazar con barra de progreso lineal (height 4px, borde-radius 2, verde)
- El resumen del paso 3 es una card de texto plano — podría usar íconos para cada línea para hacerlo más visual
- La transición entre pasos (slide translateX) es sutil — podría ser un poco más expresiva

---

## PANTALLA: OpenRequestScreen (Cliente — Mis solicitudes)

### Tab "Nueva solicitud"
- Banner informativo verde al inicio
- 11 secciones numeradas con scroll (género, tipo, hora, duración, personas, ciudad, dirección, techado, tamaño, sonido, comentarios)
- Botón "⚡ Enviar solicitud" verde al final

### Tab "Mis solicitudes"
- Lista de cards (una por solicitud)
- Card normal (status "open" o "accepted"):
  - Tipo evento (capitalizado) + género (gris) — izquierda
  - Badge de status (borde coloreado, fondo translúcido) — derecha
  - Fecha + duración + ciudad — segunda línea
- Card en negociación (`en_negociacion`) — borde y fondo amarillo translúcido:
  - Cabecera igual
  - Box de propuesta (fondo amarillo muy translúcido, borde amarillo):
    - Avatar del grupo (48px redondeado) + nombre + ciudad + botón "Ver perfil →" (verde)
    - Desglose de precio (negro semi-transparente):
      - Precio/hora, duración, subtotal (texto gris)
      - Traslado (si aplica)
      - **Total** (separador, texto blanco + número amarillo grande)
      - Hora de llegada / hora de inicio música
    - Notas del grupo (cursiva, gris)
  - Texto "¿Contratas a este grupo para tu evento?"
  - Dos botones: "❌ Buscar otro" (borde rojo 1px) | "✅ Contratar" (verde sólido)
- Botón "Cancelar solicitud" (borde rojo, visible solo si status = 'open')

### Sugerencias de diseño
- **PROBLEMA ALTO**: El formulario de nueva solicitud tiene 11 secciones en un scroll muy largo — cansa visualmente
  - Sugerencia: dividir en 3 pasos como GuidedRequestScreen (ya existe y se ve mejor)
- El desglose de precio en la propuesta usa amarillo/negro — podría unificarse con el verde del tema
- **PROBLEMA MEDIO**: El estado "Esperando grupo" no tiene animación ni pulso — el usuario siente que "no pasa nada"
  - Sugerencia: agregar un ícono girando o un indicador de actividad sutil

---

## PANTALLA: GroupOpenRequestsScreen (Grupo — Ver solicitudes)

### Elementos
1. Header: "Solicitudes abiertas" + flecha atrás
2. Chips de filtro (scroll horizontal): todos los géneros disponibles
3. Lista de cards de solicitudes:
   - Emoji + tipo de evento + género + badge de status
   - Íconos Calendar / Clock con fecha y hora
   - Ícono MapPin con ciudad y estado
   - Ícono Users con número de invitados
   - Tiempo restante antes de expirar (texto verde/naranja/rojo)
   - Botón "Ver detalles →"

### Modal de detalle (se abre al tocar una card)
- Mapa oscuro (dark style Google Maps) al 40% del alto del modal
  - Círculo de ~2km sobre la ciudad (color verde translúcido)
  - Línea de polyline desde el grupo hasta la zona del evento
  - **NO muestra la dirección exacta** (privacidad hasta el pago)
- Detalles completos del evento (tipo, fecha, hora, duración, invitados)
- Techado / tamaño / sonido (con labels descriptivos)
- Comentarios del cliente (si los hay)
- Botón "Proponer precio" (verde, full-width)

### Sugerencias de diseño
- **PROBLEMA MEDIO**: La cuenta regresiva de expiración siempre tiene el mismo color verde — cuando quedan menos de 5 minutos debería cambiar a rojo con animación urgente
- El mapa del modal es la feature más diferenciadora — darle más altura (50-60% del modal en lugar del 40%)
- Los chips de filtro de género podrían mostrar el count de solicitudes disponibles

---

## PANTALLA: GroupQuoteDetailScreen (Grupo responde cotización)

### Elementos
1. Header: flecha + "Responder cotización"
2. Card de detalles del evento (fondo `#0e0e0e`, borde `#1C1C1C`):
   - Tipo, fecha, hora, invitados, zona del evento
   - Techado, tamaño del lugar, sonido
3. Sección "Tu cotización":
   - TextInput: precio por hora → calcula total automáticamente en tiempo real
   - Desglose comisión (actualiza en tiempo real):
     ```
     Precio base:      $X,XXX
     Comisión app (10%): -$XXX
     Tus ganancias:    $X,XXX   ← verde
     ```
   - TextInput: costo de traslado
   - 3 TextInputs de horas extra (obligatorios) con desglose del 10% c/u
   - TextInput: número de integrantes → aparecen N inputs de distribución
   - TextArea: notas del grupo
4. Dos botones: "Rechazar" (borde rojo) | "Enviar cotización" (verde)

### Sugerencias de diseño
- **PROBLEMA MEDIO**: Los 3 campos de horas extra no tienen explicación clara de para qué sirven
  - Sugerencia: agregar texto hint: "El cliente podrá contratar horas extra durante el evento"
- La distribución de pago entre integrantes (N inputs de texto libre) es confusa
  - Sugerencia: mostrar el total automáticamente y distribuir igual por defecto, con opción de editar
- El ícono (i) de información junto a "Comisión 10%" debería abrir un tooltip explicativo

---

## PANTALLA: ClientQuoteDetailScreen (Cliente ve cotización del grupo)

### Elementos
1. Header: flecha + "Cotización recibida" + nombre del grupo
2. Banner de status (si ya aceptada → verde, si cancelada → rojo)
3. Card central de precio (fondo `#0e0e0e`, borde verde):
   - "Total cotizado" (gris, 13px)
   - Monto en verde Syne 26px
   - "Incluye $X de traslado" (si aplica)
4. Sección "Detalles del evento" (filas label/valor):
   - Tipo, Fecha, Duración, Hora
5. Sección "Horas extra disponibles":
   - Nota explicativa azul-gris
   - Filas: "+1 hora extra → $X,XXX", "+2 horas → $X,XXX", etc.
6. Sección "Notas del grupo" (fondo `#151515`, texto cursiva)
7. Si pendiente de respuesta: dos botones:
   - "Cancelar" (borde rojo, flex:1) | "Contratar y pagar" (verde, flex:2)

### Sugerencias de diseño
- **PROBLEMA MEDIO**: Después de aceptar, el cliente no sabe qué espera — agregar mensaje "El grupo confirmará en las próximas horas"
- La card de precio verde es el elemento más importante pero solo tiene el número — agregar desglose resumido: precio/h × horas
- Las horas extra están en la pantalla pero son secundarias — podrían estar en un acordeón colapsable

---

## PANTALLA: EventTimerScreen (Timer del evento)

### Modo Grupo (activo — !readOnly)

**Elementos (de arriba a abajo):**
1. Header oscuro: flecha + nombre del cliente + badge de status
2. **Ring SVG circular** (el elemento central — muy importante visualmente):
   - Anillo base gris oscuro `#1C1C1C`
   - Anillo de progreso verde `#00E676` (animado con dashOffset SVG)
   - Pulsación suave en loop cuando está corriendo (escala 1.0 → 1.03 → 1.0, 3.6s ciclo)
   - Glow verde exterior animado
   - Tiempo transcurrido centrado (h:mm:ss, Syne ExtraBold, blanco)
   - Texto del segmento actual (MÚSICA / DESCANSO, debajo del tiempo)
3. Sección de control:
   - Si !hasArrived: botón outline verde "📍 Llegué al lugar"
   - Si hasArrived y !started: hora de llegada gris + botón verde "▶ Iniciar evento"
   - Texto countdown "Podrás iniciar en X:XX" si no es la hora todavía
4. **Mapa exacto** (visible solo si payment_status='deposit_paid' y !readOnly):
   - Label "📍 Ubicación exacta del evento"
   - MapView 200px de alto, dark style, zoom y scroll habilitados
   - Marker rojo en las coordenadas exactas
   - Botón "📍 Abrir en Google Maps" (borde verde)
5. Sección de schedule (franjas de tiempo: MÚSICA 20:00-21:00, DESCANSO 21:00-21:15, etc.)
6. Ícono de chat con badge de mensajes no leídos
7. Si hay horas extra contratadas: sección adicional

### Modo Cliente (!readOnly)
- Igual que el modo grupo pero:
  - No muestra botones de control (sin "Llegué", sin "Iniciar")
  - Solo ve el temporizador en tiempo real
  - Ve el schedule de descansos
  - Ve el mapa exacto (si pagó)
  - Ve el chat

### Pantalla de Celebración (al finalizar)
- Fondo `#040404` con partículas de emoji animadas en explosión (24 partículas)
- Emoji 🎉 (80px)
- "¡Evento finalizado!" (Syne 34px)
- Card verde con pago del usuario (si es integrante)
- Card distribución completa (solo para el dueño del grupo)
- Botón "Volver al inicio"

### Sugerencias de diseño
- **PROBLEMA MEDIO**: El ring SVG es visualmente fuerte pero no muestra el tiempo RESTANTE — solo el transcurrido. Agregar tiempo restante como texto secundario debajo del ring
- **PROBLEMA ALTO**: El botón de chat está en el header (ícono pequeño) — durante el evento activo el chat es muy importante, debería ser un FAB (botón flotante) verde en la esquina inferior derecha
- El mapa exacto no tiene título visible que lo diferencie claramente — agregar header "📍 Dirección exacta del cliente"
- El modo cliente y el modo grupo son visualmente idénticos — considerar un color o badge diferente en el header para distinguirlos

---

## PANTALLA: GroupDashboard (Dashboard del Grupo)

### Elementos
1. Header:
   - Foto de perfil circular (80px) + nombre del grupo + badge "✅ Verificado" + badge de nivel
   - Botón de notificaciones (der)
2. Stats financieras (grid 2×2 de cards pequeñas):
   - Ingresos totales, Este mes, Pendientes, Completados
3. Alertas urgentes (cards naranja/roja si hay algo pendiente)
4. Acciones rápidas (fila de íconos con labels):
   - Reservas, Cotizaciones, Solicitudes express, Ganancias
5. Sección "Próximos eventos" — lista de reservas activas
6. Sección de gestión:
   - Verificación, Disponibilidad, Integrantes, Paquetes, Estadísticas

### Sugerencias de diseño
- **PROBLEMA MEDIO**: Las stats son números estáticos sin contexto — no se sabe si es bueno o malo
  - Sugerencia: agregar comparación "vs mes anterior" o una barra de progreso hacia una meta
- Agregar un widget "¿Qué tengo que hacer hoy?" al inicio del dashboard — cotizaciones pendientes, reservas de hoy
- Los botones de gestión en la parte de abajo no se ven a primera vista en dispositivos con pantalla pequeña — reorganizar por prioridad

---

## PANTALLA: MapAddressPicker (Selector de dirección)

### Elementos
1. Mapa full-screen (Google Maps, sin dark style — es el mapa nativo)
2. Pin rojo fijo al centro (44px, puntero hacia abajo)
3. Barra superior (posición absolute):
   - Botón X circular (izquierda)
   - Buscador con ícono Search, bordes redondeados, fondo `#0e0e0e`
   - Si está buscando: ActivityIndicator verde
4. Lista de resultados (si el usuario busca — posición absolute debajo de la barra):
   - Cards con ícono MapPin verde + nombre de lugar
   - Fondo `#0e0e0e`, borde `#1C1C1C`
5. Botón "Mi ubicación" circular blanco (derecha, posición absolute)
6. Card inferior oscura (bottom sheet fijo):
   - Handle (barra gris pequeña)
   - Si geocodeando: spinner + "Detectando dirección…"
   - Si detectó: ícono MapPin verde + dirección (SemiBold) + municipio/estado (gris)
   - Botón "✅ Confirmar esta dirección" (verde, full-width) — desactivado mientras geocodea
   - Link "Escribir dirección manualmente" (gris, centrado)

### Sugerencias de diseño
- El mapa es el elemento central y está bien implementado
- **MEJORA**: Mostrar una pequeña preview animada del pin cuando el mapa se mueve (el pin salta hacia arriba ligeramente) — es una convención visual estándar en apps como Uber/Google Maps
- El botón "Mi ubicación" es blanco (no respeta el tema oscuro) porque el MapView nativo usa el estilo por defecto — podría oscurecerse con un fondo `#0e0e0e`
