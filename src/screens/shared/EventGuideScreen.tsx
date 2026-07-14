/**
 * EventGuideScreen — "¿Cómo funciona el evento?" (cliente y grupo).
 *
 * Guía paso a paso por rol + la tarjeta compartida clave:
 * ⏱️ EL TEMPORIZADOR ES LA PRUEBA — GPS de llegada, PIN de inicio,
 * descansos y fin automático quedan registrados en el servidor y son
 * la evidencia oficial ante cualquier aclaración o disputa.
 *
 * Accesible desde el pie de la lista de eventos de ambos roles.
 */
import React from 'react';
import { ScrollView, StyleSheet, Text, View, Pressable } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

function Step({ n, icon, title, children }: {
  n: number; icon: string; title: string; children: React.ReactNode;
}) {
  return (
    <View style={s.step}>
      <View style={s.stepLeft}>
        <View style={s.stepNum}><Text style={s.stepNumTx}>{n}</Text></View>
        <View style={s.stepLine} />
      </View>
      <View style={s.stepBody}>
        <Text style={s.stepTitle}>{icon} {title}</Text>
        <Text style={s.stepText}>{children}</Text>
      </View>
    </View>
  );
}

const B = ({ children }: { children: React.ReactNode }) => <Text style={s.bold}>{children}</Text>;

export default function EventGuideScreen({ route, navigation }: any) {
  const role: 'client' | 'group' = route?.params?.role === 'group' ? 'group' : 'client';
  const isGroup = role === 'group';

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()} hitSlop={8}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={{ flex: 1 }}>
            <Text style={s.headerTitle}>¿Cómo funciona el evento?</Text>
            <Text style={s.headerSub}>{isGroup ? 'Guía para tu grupo' : 'Guía para tu evento'}</Text>
          </View>
        </View>

        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          {/* ⏱️ LA TARJETA CLAVE — la ven los dos */}
          <View style={s.proofCard}>
            <Text style={s.proofTitle}>⏱️ El temporizador es LA PRUEBA</Text>
            <Text style={s.proofText}>
              La llegada verificada por GPS, la hora exacta de inicio con el PIN, los descansos
              y el fin automático quedan <B>registrados en el servidor</B>. Ese registro es la{' '}
              <B>evidencia oficial</B> de qué pasó en el evento: nadie — ni el cliente ni el
              grupo — puede alterarlo, y con él se resuelve cualquier aclaración o disputa.
            </Text>
          </View>

          {isGroup ? (
            <View style={s.steps}>
              <Step n={1} icon="✅" title="Confirma y prepárate">
                Cuando el cliente paga, su dinero queda <B>en custodia</B> — la fecha es tuya.
                Coordina a tus integrantes (tienen su chat) y revisa la dirección en tu evento.
              </Step>
              <Step n={2} icon="🚐" title='Presiona "Voy en camino"'>
                El día del evento, al salir, ábrelo en tus eventos y presiona{' '}
                <B>"Voy en camino"</B>: el cliente te ve acercarte en su mapa. Sal con tiempo —
                el traslado cuenta y la app te recuerda si no avanzas.
              </Step>
              <Step n={3} icon="📍" title='Al llegar: "Llegué al evento"'>
                El GPS verifica que estás en el lugar (a menos de 250 m). Esa llegada queda
                registrada — es tu protección contra reclamos de "no llegó".
              </Step>
              <Step n={4} icon="🔢" title="Pide el PIN y elige descansos">
                El cliente tiene un <B>PIN de inicio</B> en su app — pídeselo, elige el tipo de
                descanso con él (por hora, único o sin descanso) y arranca el temporizador.
              </Step>
              <Step n={5} icon="🎵" title="A tocar — los descansos son automáticos">
                El temporizador marca cuándo tocar y cuándo descansar según lo elegido, y le
                avisa al cliente solo. Tú solo síguelo.
              </Step>
              <Step n={6} icon="➕" title="Ofrece horas extra (si se puede)">
                Si el cliente quiere más fiesta, ofrécelas desde el temporizador — se cobran por
                la app. Si tienes otra tocada después ese día, la opción no aparece.
              </Step>
              <Step n={7} icon="🏁" title="El evento termina SOLO">
                Al cumplirse el tiempo (contratado + extras) el evento cierra automáticamente y{' '}
                <B>tu pago completo se libera a tu wallet</B>. Nadie puede finalizarlo a mano.
                Después, califica al cliente.
              </Step>
            </View>
          ) : (
            <View style={s.steps}>
              <Step n={1} icon="💳" title="Pagas y tu dinero queda protegido">
                Tu pago <B>no se le entrega al grupo</B>: queda en custodia de Daricefy y solo se
                libera cuando el evento se cumple.
              </Step>
              <Step n={2} icon="🚐" title="El grupo va en camino">
                El día del evento te avisamos cuando el grupo sale — lo ves{' '}
                <B>acercarse en tu mapa</B> y te llega un aviso cuando ya mero llega, para que lo
                recibas.
              </Step>
              <Step n={3} icon="📍" title="Llegada verificada por GPS">
                Cuando el grupo llega, su ubicación se verifica a menos de 250 m del lugar. Esa
                llegada queda registrada — es tu protección.
              </Step>
              <Step n={4} icon="🔢" title="Tú das el PIN de inicio">
                En tu evento aparece un <B>PIN de 4 dígitos</B>: dáselo al grupo cuando estén
                listos para empezar. Solo con tu PIN arranca el temporizador —{' '}
                <B>no lo compartas antes</B>.
              </Step>
              <Step n={5} icon="⏱️" title="El temporizador corre">
                Ves en vivo el tiempo tocado y los descansos del grupo (la app te avisa cuándo
                empiezan y cuándo vuelven a tocar).
              </Step>
              <Step n={6} icon="➕" title="¿Quieren más fiesta? Horas extra">
                Cerca del final puedes pedir horas extra desde tu evento — se pagan por la app y
                el temporizador se extiende al instante.
              </Step>
              <Step n={7} icon="🏁" title="Termina solo — y calificas">
                El evento cierra automáticamente al cumplirse el tiempo; hasta entonces el grupo
                recibe su pago. Al final, califica al grupo — tu opinión cuida a los demás
                clientes.
              </Step>
            </View>
          )}

          <Text style={s.footer}>
            ¿Algo salió diferente? Repórtalo desde Soporte — el registro del temporizador
            respalda la aclaración. Consulta también las Políticas de cancelación.
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
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },
  scroll: { padding: SPACING.xl, paddingBottom: 40 },

  proofCard: {
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.4)', padding: 16, marginBottom: 20,
  },
  proofTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green, marginBottom: 6 },
  proofText:  { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.text, lineHeight: 19 },

  steps: { gap: 0 },
  step: { flexDirection: 'row', gap: 12 },
  stepLeft: { alignItems: 'center', width: 30 },
  stepNum: {
    width: 28, height: 28, borderRadius: 14, alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,230,118,0.12)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.45)',
  },
  stepNumTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  stepLine: { flex: 1, width: 1.5, backgroundColor: 'rgba(0,230,118,0.18)', marginVertical: 4 },
  stepBody: { flex: 1, paddingBottom: 20 },
  stepTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: COLORS.text, marginBottom: 4 },
  stepText:  { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2, lineHeight: 18 },
  bold: { fontFamily: FONTS.bodySemiBold, color: COLORS.text },

  footer: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 17, textAlign: 'center', marginTop: 8 },
});
