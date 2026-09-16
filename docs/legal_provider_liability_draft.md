# Borrador: protección legal de Daricefy frente a proveedores y clientes

**⚠️ AVISO IMPORTANTE — LÉELO PRIMERO**

No soy abogado y esto no es asesoría legal. Es un borrador razonado, basado en
cómo ya está armada tu app y en cláusulas estándar que usan plataformas como
Uber, Airbnb o DoorDash para protegerse como "solo conectamos" — pero las
leyes de responsabilidad civil, protección al consumidor y salud pública
cambian por país y por estado, y tú operas en México y Estados Unidos (y
piensas entrar a Canadá). **Antes de que esto sea real (que un proveedor lo
firme o que dependas de él en una demanda), pásaselo a un abogado real —
mexicano para lo de México, uno de EE.UU. para lo de allá.** Esto te ahorra
tiempo y te dice qué preguntarle, no reemplaza su revisión.

---

## 1. Lo que ya tienes (y por qué no basta)

`LegalScreen.tsx`, sección 9 ("Limitación de responsabilidad"), dice hoy:

> "No es responsable por daños derivados del **servicio musical**..."

Ese texto se escribió cuando la app solo tenía grupos musicales. Hoy también
hay Comida, Renta de mobiliario, Fotografía, Shows, DJ, etc. — y la palabra
**"musical"** deja fuera, literalmente, a todas las demás categorías. Si
alguien se intoxica con comida de un proveedor, o un brincolín rentado
lastima a un niño, el texto actual no los cubre porque solo habla de
música. Ese es el hueco real que hay que cerrar primero, antes de cualquier
documento nuevo.

## 2. Categorías que existen hoy y su riesgo real

| Categoría | Riesgo específico |
|---|---|
| Grupo musical / Solista / DJ / MC / Comediante | Derechos de autor de la música que tocan (SACM en México, ASCAP/BMI/SESAC en EE.UU.), ruido/permisos del lugar, calidad del show |
| Shows (payasos, mago, personajes, animación) | Seguridad física con niños, contacto físico, alergias a maquillaje/pintura |
| Luz y sonido | Instalación eléctrica, cableado, riesgo de descarga o incendio |
| **Comida** | Intoxicación alimentaria, manejo de alérgenos, permisos sanitarios (COFEPRIS/salud municipal en México; health permit por condado en EE.UU.) |
| **Renta** (mesas, sillas, toldos, tarimas, generadores, brincolines, inflables) | Daño a la propiedad del lugar, lesión por mal armado (un brincolín/tarima que colapsa es el ejemplo más serio) |
| Fotógrafos / Drones / Cabina 360 | Uso de imagen de invitados sin permiso, dron volando sobre gente (regulación de aviación civil), daño a propiedad |

Ninguna de estas siete filas está mencionada hoy en tus Términos. Eso es lo
que hay que corregir.

## 3. Arreglo #1 — ampliar la sección 9 de tus Términos (reemplazo directo)

Cambiar el texto actual por uno que ya no diga "musical" sino "cualquier
categoría", y que agregue una cláusula de **indemnización** (el usuario se
compromete a no meterte en gastos si lo demandan a él). Texto propuesto:

> **9. Limitación de responsabilidad**
>
> Daricefy es un intermediario tecnológico. Responde por la gestión y
> custodia del pago conforme a sus políticas, pero **no presta, supervisa
> ni garantiza** el servicio contratado — musical, de comida, de
> mobiliario, fotográfico o de cualquier otra categoría disponible en la
> plataforma. El proveedor (grupo, talento o negocio) es el **único
> responsable** de contar con los permisos, licencias sanitarias, seguros
> y capacitación necesarios para prestar su servicio conforme a la ley
> aplicable, y de la calidad, seguridad y legalidad de lo que ofrece.
>
> Daricefy no es responsable por daños a personas o propiedad, intoxicación,
> lesión, incumplimiento de derechos de autor, ni por cualquier otro
> perjuicio derivado del servicio contratado, del lugar del evento, o de
> caso fortuito o fuerza mayor. En cualquier caso, la responsabilidad total
> de Daricefy frente a cualquier usuario se limita al monto de la operación
> en cuestión, y en ningún caso incluye daños indirectos, consecuenciales
> o lucro cesante.
>
> **Indemnización.** Si un tercero presenta una reclamación o demanda
> contra Daricefy derivada del servicio que tú prestaste o contrataste,
> aceptas defender a Daricefy, cubrir sus gastos legales razonables y
> mantenerla en paz y a salvo frente a esa reclamación.

## 4. Arreglo #2 — Acuerdo de Proveedor (documento nuevo, aparte de los Términos)

Los Términos los acepta TODO mundo (clientes incluidos) al registrarse — son
generales. Lo que de verdad te protege fuerte es un documento que **solo
firme el proveedor** al aceptar su primera cotización o al ser aprobado
(en `admin_approve_provider_application`, o la primera vez que responde una
cotización). Aquí sí puedes ser específico por categoría sin ensuciar los
Términos generales.

### 4.1 Núcleo común (aplica a todos)

> Al ofrecer tus servicios en Daricefy, declaras y garantizas que:
>
> 1. Actúas como **proveedor independiente**, no como empleado, socio ni
>    representante de Daricefy.
> 2. Cuentas con la **capacidad legal, permisos, licencias, seguros y
>    experiencia** necesarios para prestar tu servicio conforme a la ley del
>    lugar donde lo prestarás.
> 3. Eres el único responsable de la **calidad, seguridad y legalidad** de
>    lo que ofreces, incluyendo cualquier daño, lesión o perjuicio que tu
>    servicio cause a clientes, invitados o terceros.
> 4. Mantendrás a Daricefy libre de toda responsabilidad, y la
>    **indemnizarás** por cualquier reclamación derivada de tu servicio.
> 5. Daricefy únicamente conecta, cotiza y procesa el pago — no supervisa,
>    inspecciona ni certifica tu trabajo.

### 4.2 Anexos por categoría (se muestra solo el que aplique, según `groups.genre`)

**Comida:**
> Declaras contar con los permisos sanitarios vigentes que exija tu
> localidad para preparar y/o servir alimentos, manejar correctamente
> alérgenos comunes, e informar al cliente si tu menú los contiene. Eres el
> único responsable ante cualquier intoxicación, alergia o incidente
> relacionado con los alimentos que sirvas.

**Renta de mobiliario (mesas, sillas, toldos, tarimas, generadores,
brincolines, inflables):**
> Declaras que tu equipo está en condiciones seguras de uso, que lo
> instalarás/armarás conforme a las especificaciones del fabricante, y que
> cuentas con seguro de responsabilidad civil si tu equipo representa
> riesgo físico (inflables, tarimas, generadores eléctricos). Eres el único
> responsable por daños a la propiedad del lugar o lesiones causadas por tu
> equipo.

**Shows (payasos, mago, personajes, animación):**
> Declaras tener experiencia trabajando con el público de tu show
> (incluyendo menores de edad cuando aplique), usar materiales
> (maquillaje, pintura, accesorios) seguros e hipoalergénicos, y asumes
> responsabilidad por cualquier incidente físico durante tu actuación.

**Luz y sonido:**
> Declaras que tu instalación eléctrica cumple con normas de seguridad
> básicas y que cuentas con el conocimiento técnico para instalar tu
> equipo sin representar riesgo de descarga o incendio.

**Fotógrafos / Drones / Cabina 360:**
> Declaras contar con el permiso correspondiente para operar drones donde
> la ley lo exija, y ser responsable de obtener el consentimiento de las
> personas que fotografíes/grabes cuando el uso de esas imágenes lo
> requiera.

**Música/DJ/MC/Comediante:**
> Declaras contar con los derechos o licencias necesarias para interpretar
> o reproducir la música/material de tu show (SACM u organismo equivalente
> en tu país), y ser responsable de cualquier reclamación por derechos de
> autor derivada de tu presentación.

## 5. Arreglo #3 — aviso corto para el cliente (esto SÍ debe verse en la app)

Pediste que si un cliente te demanda, también quede claro. La pieza más
fuerte para eso no es un documento aparte que casi nadie lee — es un aviso
corto, imposible de ignorar, en el momento de pagar. Ejemplo de texto para
un banner antes de confirmar el pago:

> **Antes de pagar:** Daricefy conecta y cotiza, pero el servicio lo presta
> **[nombre del proveedor]**, un proveedor independiente — no un empleado
> de Daricefy. Daricefy no es responsable por la calidad, seguridad o
> legalidad de lo que el proveedor entregue. Cualquier reclamo sobre el
> servicio en sí se resuelve directamente con el proveedor; Daricefy ayuda
> con evidencia (chat, GPS, pagos) pero no es parte del servicio contratado.

Esto además refuerza (con fecha y aceptación registrada) que el cliente vio
el aviso antes de pagar — eso es lo que de verdad ayuda si algún día alguien
te demanda a ti en vez de al proveedor real.

## 6. Qué falta para que esto sea real (próximos pasos, no hechos todavía)

Esto es solo el texto — falta:

1. Que un abogado (uno en México, uno en EE.UU.) lo revise y ajuste a la
   ley real de cada país/estado donde operas.
2. Decidir CUÁNDO se acepta el Acuerdo de Proveedor — ¿al aprobar su
   solicitud (`admin_approve_provider_application`)? ¿la primera vez que
   responde una cotización? Necesita quedar un registro con fecha
   (`provider_agreements` o similar) de que lo aceptó, no solo un texto en
   pantalla.
2. Igual para el aviso al cliente — un checkbox o banner en el momento del
   pago, con su propio registro de aceptación.
3. Traducir la versión en inglés para tus proveedores/clientes de EE.UU.
   (los Términos de hoy solo existen en español).

No armé el código/base de datos de esto todavía — es apropósito, primero
necesitas leer el texto, decidir si es lo que quieres decir, y (ojalá)
pasarlo por un abogado antes de que yo lo conecte a la app.
