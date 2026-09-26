/**
 * ProviderApplyScreen — solicitud pública para grupos/proveedores nuevos.
 *
 * Pantalla SIN sesión (registrada junto a Login/Register/Legal). Antes,
 * cualquiera podía registrarse directo como "Soy Prestador" y tener cuenta
 * funcional al instante — ahora esa opción se quitó del registro y todo
 * proveedor nuevo pasa por aquí: manda sus datos, un asesor lo contacta por
 * WhatsApp para pedirle foto + hasta 3 videos (no hay subida sin sesión en
 * la app), y si se aprueba, se le crea su cuenta ya en modo conserjería
 * (sql/649). No pide contraseña ni crea nada — solo inserta una solicitud.
 */
import { ArrowLeft, Briefcase, Clock, MapPin, Phone, User } from 'lucide-react-native';
import React, { useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';
import Particles from '../../components/ui/Particles';
import { PROVIDER_CATEGORIES } from '../../constants/providerCategories';

const COUNTRIES = ['México', 'Estados Unidos', 'Canadá'];

export default function ProviderApplyScreen({ navigation }: any) {
  const [fullName, setFullName]   = useState('');
  const [phone, setPhone]         = useState('');
  const [category, setCategory]   = useState<string | null>(null);
  const [years, setYears]         = useState('');
  const [minHours, setMinHours]   = useState('');
  const [country, setCountry]     = useState('México');
  const [state, setState]         = useState('');
  const [city, setCity]           = useState('');
  const [notes, setNotes]         = useState('');
  const [loading, setLoading]     = useState(false);
  const [sent, setSent]           = useState(false);

  const canSend = fullName.trim().length > 1 && phone.trim().length > 6 && !!category;

  const handleSend = async () => {
    if (!canSend) {
      Alert.alert('Faltan datos', 'Escribe tu nombre, teléfono y elige tu categoría.');
      return;
    }
    setLoading(true);
    const { data, error } = await supabase.rpc('submit_provider_application', {
      p_full_name: fullName.trim(),
      p_phone: phone.trim(),
      p_category: category,
      p_years_experience: years ? parseInt(years, 10) : null,
      p_min_hours: minHours ? parseFloat(minHours) : null,
      p_country: country,
      p_state: state.trim() || null,
      p_city: city.trim() || null,
      p_notes: notes.trim() || null,
    });
    setLoading(false);

    if (error || !data?.ok) {
      const err = data?.error;
      const msg =
        err === 'too_many_pending' ? 'Ya tienes varias solicitudes pendientes — espera a que te contactemos.' :
        err === 'invalid_category' ? 'Elige una categoría válida.' :
        error?.message ?? 'No se pudo enviar tu solicitud. Intenta de nuevo.';
      Alert.alert('No se pudo enviar', msg);
      return;
    }
    setSent(true);
  };

  if (sent) {
    return (
      <View style={s.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1, justifyContent: 'center' }}>
          <View style={s.successBox}>
            <Text style={s.successEmoji}>✅</Text>
            <Text style={s.successTitle}>¡Solicitud enviada!</Text>
            <Text style={s.successSub}>
              Un asesor te va a contactar por WhatsApp al número que dejaste
              para pedirte tu foto y hasta 3 videos. Si todo va bien, te
              creamos tu cuenta y te pasamos tu acceso.
            </Text>
            <Button label="Volver" onPress={() => navigation?.goBack?.()} size="lg" />
          </View>
        </SafeAreaView>
      </View>
    );
  }

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          <ScrollView contentContainerStyle={s.scroll} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>
            <View style={s.header}>
              <Pressable onPress={() => navigation?.goBack?.()} style={s.backBtn}>
                <ArrowLeft size={18} color={COLORS.text} />
              </Pressable>
              <Text style={s.logo}>Darice<Text style={{ color: COLORS.green }}>fy</Text></Text>
            </View>

            <Text style={s.title}>Postúlate como proveedor</Text>
            <Text style={s.subtitle}>
              Queremos conocerte antes de darte cuenta — cuéntanos de ti y te
              contactamos por WhatsApp.
            </Text>

            <Input
              label="Nombre o nombre del grupo"
              placeholder="Ej. Banda Los Ejemplares"
              value={fullName}
              onChangeText={setFullName}
              icon={<User size={18} color={COLORS.muted} />}
            />
            <Input
              label="Teléfono (WhatsApp)"
              placeholder="Ej. 33 1234 5678"
              value={phone}
              onChangeText={setPhone}
              keyboardType="phone-pad"
              icon={<Phone size={18} color={COLORS.muted} />}
            />

            <Text style={s.label}>¿A qué te dedicas?</Text>
            <View style={s.categoryGrid}>
              {PROVIDER_CATEGORIES.map(cat => (
                <Pressable
                  key={cat.key}
                  style={[s.catCard, category === cat.key && s.catCardActive]}
                  onPress={() => setCategory(cat.key)}
                >
                  <Text style={s.catEmoji}>{cat.emoji}</Text>
                  <Text style={[s.catLabel, category === cat.key && s.catLabelActive]}>
                    {catLabel(cat.key)}
                  </Text>
                </Pressable>
              ))}
            </View>

            <View style={s.row}>
              <View style={{ flex: 1 }}>
                <Input
                  label="Años de trayectoria"
                  placeholder="Ej. 5"
                  value={years}
                  onChangeText={t => setYears(t.replace(/[^0-9]/g, ''))}
                  keyboardType="numeric"
                  icon={<Briefcase size={18} color={COLORS.muted} />}
                />
              </View>
              <View style={{ width: 12 }} />
              <View style={{ flex: 1 }}>
                <Input
                  label="Horas mínimas de contratación"
                  placeholder="Ej. 3"
                  value={minHours}
                  onChangeText={t => setMinHours(t.replace(/[^0-9.]/g, ''))}
                  keyboardType="numeric"
                  icon={<Clock size={18} color={COLORS.muted} />}
                />
              </View>
            </View>

            <Text style={s.label}>País</Text>
            <View style={s.pillRow}>
              {COUNTRIES.map(c => (
                <Pressable key={c} style={[s.pill, country === c && s.pillActive]} onPress={() => setCountry(c)}>
                  <Text style={[s.pillText, country === c && s.pillTextActive]}>{c}</Text>
                </Pressable>
              ))}
            </View>

            <View style={s.row}>
              <View style={{ flex: 1 }}>
                <Input label="Estado" placeholder="Ej. Jalisco" value={state} onChangeText={setState} icon={<MapPin size={18} color={COLORS.muted} />} />
              </View>
              <View style={{ width: 12 }} />
              <View style={{ flex: 1 }}>
                <Input label="Ciudad" placeholder="Ej. Zapopan" value={city} onChangeText={setCity} />
              </View>
            </View>

            <Input
              label="Cuéntanos algo más (opcional)"
              placeholder="Ej. tocamos en bodas y XV años, tenemos equipo propio..."
              value={notes}
              onChangeText={setNotes}
              multiline
              numberOfLines={3}
            />

            <Text style={s.hint}>
              Después de enviar esto, un asesor te va a contactar por
              WhatsApp; te va a pedir que mandes tu foto y hasta 3 videos
              para terminar de darte de alta.
            </Text>

            <Button
              label={loading ? 'Enviando...' : 'Enviar solicitud'}
              onPress={handleSend}
              loading={loading}
              disabled={!canSend}
              size="lg"
            />
          </ScrollView>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </View>
  );
}

function catLabel(key: string): string {
  const map: Record<string, string> = {
    grupo: 'Grupo musical', solista: 'Solista', dj: 'DJ', comediante: 'Comediante',
    espectaculo: 'Show', mc: 'Maestro de Ceremonias', luzSonido: 'Luz y sonido',
    comida: 'Amenidades y Snacks', renta: 'Renta de mobiliario', fotografos: 'Fotografía/Video',
  };
  return map[key] ?? key;
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  scroll: { padding: SPACING.xl, paddingBottom: 48 },
  header: { flexDirection: 'row', alignItems: 'center', gap: 12, marginBottom: 20 },
  backBtn: {
    width: 36, height: 36, borderRadius: 12, backgroundColor: COLORS.card,
    borderWidth: 1, borderColor: COLORS.border, alignItems: 'center', justifyContent: 'center',
  },
  logo: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  title: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, marginBottom: 6 },
  subtitle: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 20, lineHeight: 18 },
  label: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  row: { flexDirection: 'row' },

  categoryGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 16 },
  catCard: {
    width: '31%', paddingVertical: 12, borderRadius: RADIUS.md,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', gap: 4,
  },
  catCardActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  catEmoji: { fontSize: 20 },
  catLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, textAlign: 'center' },
  catLabelActive: { color: COLORS.green, fontFamily: FONTS.bodyMedium },

  pillRow: { flexDirection: 'row', gap: 8, marginBottom: 16 },
  pill: {
    paddingHorizontal: 14, paddingVertical: 9, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  pillActive: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  pillText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  pillTextActive: { color: COLORS.bg },

  hint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 17, marginBottom: 20 },

  successBox: { alignItems: 'center', paddingHorizontal: SPACING.xl, gap: 14 },
  successEmoji: { fontSize: 48 },
  successTitle: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, textAlign: 'center' },
  successSub: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 20, marginBottom: 10 },
});
