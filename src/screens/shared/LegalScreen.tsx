/**
 * LegalScreen — Términos y Condiciones / Aviso de Privacidad.
 *
 *   route.params.doc: 'terms' | 'privacy'
 *
 * Accesible desde Perfil → sección Legal (todos los roles) y desde el
 * registro ("Al crear tu cuenta aceptas…"). Complementa a
 * CancellationPolicyScreen y PromotionPolicyScreen.
 *
 * Incluye la cláusula de PROPIEDAD INTELECTUAL Y RETIRO DE CONTENIDO
 * (estilo DMCA): quien sube contenido declara ser titular; Daricefy
 * retira contenido reportado y la responsabilidad recae en quien lo
 * subió — protege a la plataforma como intermediario.
 */
import React from 'react';
import { ScrollView, StyleSheet, Text, View, Pressable } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

function Section({ n, title, children }: { n: string; title: string; children: React.ReactNode }) {
  return (
    <View style={s.section}>
      <Text style={s.sectionTitle}>{n}. {title}</Text>
      <Text style={s.body}>{children}</Text>
    </View>
  );
}

const B = ({ children }: { children: React.ReactNode }) => <Text style={s.bold}>{children}</Text>;

function Terms() {
  return (
    <>
      <Section n="1" title="Qué es Daricefy">
        Daricefy es una plataforma tecnológica de <B>intermediación</B>: conecta clientes con
        grupos musicales y talentos independientes, y <B>custodia el pago</B> para proteger a las
        dos partes. El contrato de servicios musicales se celebra directamente entre cliente y
        grupo; Daricefy no es parte de él. Los grupos y talentos no son empleados, socios ni
        representantes de Daricefy.
      </Section>

      <Section n="2" title="Tu cuenta">
        Debes ser mayor de 18 años y proporcionar información veraz. Eres responsable de lo que
        ocurre con tu cuenta y de mantener tu acceso seguro. Una persona = una cuenta; las
        cuentas duplicadas o falsas se suspenden.
      </Section>

      <Section n="3" title="Lo que SÍ puedes hacer">
        Solicitar, cotizar, contratar y prestar servicios musicales dentro de la app; pagar y
        recibir pagos por los medios oficiales; calificar y ser calificado; comunicarte por los
        chats de la app; contratar los productos de publicidad disponibles para tu rol.
      </Section>

      <Section n="4" title="Lo que NO puedes hacer">
        • Cerrar tratos <B>fuera de la app</B> para evadir la plataforma (compartir teléfonos o
        redes en los chats de eventos está bloqueado y sancionado).{'\n'}
        • Publicar información falsa, perfiles falsos o manipular reseñas.{'\n'}
        • Usar la app para actividades ilegales, fraude o suplantación.{'\n'}
        • Subir contenido del que no seas titular (ver sección 6).{'\n'}
        • Acosar, discriminar o amenazar a otros usuarios.{'\n'}
        El incumplimiento genera strikes, pérdida de verificación, cancelación de promociones sin
        reembolso y/o suspensión definitiva.
      </Section>

      <Section n="5" title="Pagos, cancelaciones y si algo sale mal">
        Los pagos se procesan por proveedores certificados y quedan <B>en custodia</B>: el grupo
        los recibe cuando el evento se cumple (llegada verificada por GPS y temporizador). Las
        reglas completas de cancelaciones, reembolsos, no-shows y sanciones están en{' '}
        <B>Políticas de cancelación</B> (dentro de tus eventos) y forman parte de estos términos.
        Si algo sale mal, repórtalo desde la app: las disputas se resuelven con la evidencia
        registrada (GPS, temporizador, chat y pagos).
      </Section>

      <Section n="6" title="Contenido que subes — propiedad intelectual y retiro">
        Al subir fotos, videos, audio o textos (a tu perfil, a la publicidad pagada o a los
        chats) <B>declaras y garantizas que eres titular de los derechos</B> o que cuentas con
        autorización para usarlos, incluyendo la música que aparezca en tus videos. Otorgas a
        Daricefy una licencia no exclusiva para mostrar ese contenido dentro de la plataforma
        con fines de operación y promoción de tu propio perfil.{'\n\n'}
        <B>Retiro de contenido (takedown).</B> Si un titular de derechos nos notifica una
        presunta infracción (por Soporte, con identificación de la obra, del contenido señalado
        y sus datos de contacto), Daricefy podrá <B>retirar el contenido de inmediato</B> y
        notificar a quien lo subió, quien podrá presentar contra-aviso. La{' '}
        <B>responsabilidad por el contenido recae exclusivamente en el usuario que lo subió</B>,
        quien mantendrá a Daricefy en paz y a salvo frente a cualquier reclamación. Las cuentas
        con infracciones reiteradas se suspenden definitivamente.
      </Section>

      <Section n="7" title="Respeto entre usuarios">
        <B>Para clientes:</B> los grupos son músicos profesionales que apartan fechas y movilizan
        equipo por tu evento — cancela con anticipación, proporciona información real del lugar y
        trátalos con respeto.{'\n'}
        <B>Para grupos:</B> los clientes confían su evento a ustedes — llega a tiempo, cumple lo
        cotizado y comunica cualquier imprevisto de inmediato. Las calificaciones de ambos lados
        son públicas y permanentes.
      </Section>

      <Section n="8" title="Marca y propiedad de la plataforma">
        El nombre <B>Daricefy</B>, su logotipo, diseño, código y contenidos propios son propiedad
        de la plataforma y están protegidos por las leyes de propiedad intelectual. No pueden
        usarse, copiarse ni imitarse sin autorización escrita.
      </Section>

      <Section n="9" title="Limitación de responsabilidad">
        Daricefy responde por la gestión y custodia del pago conforme a sus políticas. No
        garantiza resultados artísticos ni comerciales, y no es responsable por daños derivados
        del servicio musical, del lugar del evento, ni por caso fortuito o fuerza mayor. En
        cualquier caso, la responsabilidad total de Daricefy se limita al monto de la operación
        en cuestión.
      </Section>

      <Section n="10" title="Cambios y ley aplicable">
        Podemos actualizar estos términos; la versión vigente estará siempre en esta pantalla y
        los cambios relevantes se avisarán en la app. Estos términos se rigen por las leyes de
        los Estados Unidos Mexicanos.
      </Section>
    </>
  );
}

function Privacy() {
  return (
    <>
      <Section n="1" title="Qué datos recopilamos">
        • <B>Cuenta:</B> nombre, correo, teléfono, foto de perfil y rol (cliente, grupo, talento).{'\n'}
        • <B>Ubicación:</B> tu estado/ciudad para mostrarte grupos de tu zona, y el GPS del grupo
        únicamente para verificar llegada al evento y el trayecto "en camino".{'\n'}
        • <B>Pagos:</B> los procesan proveedores certificados (nosotros <B>no almacenamos números
        de tarjeta</B>); guardamos referencias de la operación, y la CLABE solo cuando la
        proporcionas para reembolsos o retiros.{'\n'}
        • <B>Verificación (KYC):</B> documentos de identidad que subas para verificar tu grupo.{'\n'}
        • <B>Contenido y actividad:</B> fotos/videos que subas, mensajes de chat, cotizaciones,
        reservas, calificaciones y registros del temporizador.
      </Section>

      <Section n="2" title="Para qué los usamos">
        Operar el servicio (conectar, cotizar, pagar, verificar llegadas), proteger a ambas
        partes (custodia, disputas, prevención de fraude), notificarte lo relevante de tus
        eventos, cumplir obligaciones legales y fiscales, y mejorar la app. <B>No vendemos tus
        datos ni los compartimos con terceros</B> — solo con los procesadores de pago
        estrictamente para procesar tu operación, y con autoridades cuando la ley lo exija.
      </Section>

      <Section n="3" title="Cuánto tiempo los guardamos">
        Mientras tu cuenta exista y después solo el tiempo necesario para obligaciones legales,
        fiscales y resolución de disputas. Los mensajes del chat de evento se eliminan al
        terminar el evento. Puedes solicitar la eliminación de tu cuenta desde Soporte.
      </Section>

      <Section n="4" title="Tus derechos (ARCO)">
        Puedes <B>Acceder, Rectificar, Cancelar u Oponerte</B> al uso de tus datos, y solicitar
        su portabilidad o eliminación, escribiéndonos desde Soporte. Responderemos en los plazos
        que marca la Ley Federal de Protección de Datos Personales en Posesión de los
        Particulares (México).
      </Section>

      <Section n="5" title="Seguridad">
        Tus datos viajan cifrados y se almacenan con controles de acceso por rol: cada usuario
        solo ve lo suyo. Los pagos quedan en custodia con auditoría de cada movimiento. Ningún
        empleado o usuario puede ver datos de pago completos.
      </Section>

      <Section n="6" title="Menores de edad">
        Daricefy es para mayores de 18 años. Si detectamos una cuenta de un menor, será
        eliminada junto con sus datos.
      </Section>

      <Section n="7" title="Cambios a este aviso">
        La versión vigente estará siempre en esta pantalla; los cambios relevantes se avisarán
        dentro de la app.
      </Section>
    </>
  );
}

export default function LegalScreen({ route, navigation }: any) {
  const doc: 'terms' | 'privacy' = route?.params?.doc === 'privacy' ? 'privacy' : 'terms';
  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()} hitSlop={8}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={{ flex: 1 }}>
            <Text style={s.headerTitle}>
              {doc === 'privacy' ? 'Aviso de privacidad' : 'Términos y condiciones'}
            </Text>
            <Text style={s.headerSub}>Última actualización: julio 2026</Text>
          </View>
        </View>
        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>
          {doc === 'privacy' ? <Privacy /> : <Terms />}
          <Text style={s.footer}>
            ¿Dudas? Escríbenos desde Ayuda y soporte. Consulta también las Políticas de
            cancelación (en tus eventos) y las Políticas de promoción (en Publicidad) — forman
            parte de estos documentos.
          </Text>
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  headerTitle: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: 1 },
  scroll: { padding: SPACING.xl, paddingBottom: 40, gap: 14 },

  section: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 16,
  },
  sectionTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: COLORS.green, marginBottom: 8 },
  body: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.text, lineHeight: 19 },
  bold: { fontFamily: FONTS.bodySemiBold, color: COLORS.text },
  footer: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 17, marginTop: 4, textAlign: 'center' },
});
