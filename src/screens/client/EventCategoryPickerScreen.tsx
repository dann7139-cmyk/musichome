import { ArrowLeft, Check } from 'lucide-react-native';
import React, { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { useAuth } from '../../context/AuthContext';
// Fase 1 (sql/585). 2026-09-03 — lista movida a src/constants/providerCategories.ts
// para que el Explorador (HomeScreen) use EXACTAMENTE la misma lista y no
// se desincronicen otra vez ("quiero que las categorías sean las mismas").
import { PROVIDER_CATEGORIES as CATEGORY_OPTIONS, ProviderCategory, genreMatches } from '../../constants/providerCategories';

export default function EventCategoryPickerScreen({ route, navigation }: any) {
  const { t, i18n } = useTranslation();
  const { role } = useAuth();
  const { eventId, eventDate, eventAddress } = route?.params ?? {};
  const dateLocale = i18n.language?.startsWith('en') ? 'en-US' : 'es-MX';

  // 2026-09-16 — petición real: "que aparezca la lista de géneros para
  // elegir uno, como en la web" (antes, tocar una categoría con varios
  // géneros iba directo a resultados con TODOS mezclados — nunca dejaba
  // ver ni elegir un género específico, a diferencia del selector de la
  // web que sí los lista uno por uno agrupados por categoría).
  const [expanded, setExpanded] = useState<ProviderCategory | null>(null);

  // Fase 2 — oferta REAL por categoría. Hoy Daricefy solo tiene proveedores
  // musicales registrados, así que varias categorías llevarían a resultados
  // vacíos sin avisar y parecería un error. Se cuentan los grupos activos y se
  // marca con honestidad la categoría que todavía no tiene ninguno — nunca se
  // oculta la categoría ni se inventa disponibilidad.
  // Se usa genreMatches para que un género compuesto ("Norteño/Sierreño")
  // cuente en cada una de sus categorías, igual que el filtro del Explorador.
  const [counts, setCounts] = useState<Record<string, number> | null>(null);
  // Mismo criterio un nivel mas abajo: dentro de una categoria que si expande
  // (Grupo musical trae 52 generos), hoy 49 de esos generos no tienen ningun
  // proveedor. Sin esto, la categoria avisaba y el genero no: el cliente
  // tocaba y llegaba al Explorador vacio sin explicacion.
  const [genreCounts, setGenreCounts] = useState<Record<string, number> | null>(null);

  const fetchCounts = useCallback(async () => {
    const { data, error } = await supabase.from('groups').select('genre').eq('is_active', true);
    if (error || !data) { setCounts(null); setGenreCounts(null); return; }   // sin dato => no se marca nada
    const acc: Record<string, number> = {};
    const porGenero: Record<string, number> = {};
    for (const cat of CATEGORY_OPTIONS) {
      acc[cat.key] = data.filter((g: any) => cat.genres.some(cg => genreMatches(g.genre, cg))).length;
      for (const cg of cat.genres) {
        porGenero[cg] = data.filter((g: any) => genreMatches(g.genre, cg)).length;
      }
    }
    setCounts(acc);
    setGenreCounts(porGenero);
  }, []);

  // useFocusEffect (mismo patron que ReservationsScreen/MyEventScreen): ademas
  // de cubrir el mount, recarga el conteo al volver del Explorador.
  useFocusEffect(useCallback(() => { fetchCounts(); }, [fetchCounts]));

  const goToExplorar = (genres: string[], label: string) => {
    // Hallazgo real (2026-09-03): "si le aprieto a uno no me arroja nada".
    // Esta pantalla vive registrada suelta en el stack raíz de cada rol
    // (mismo "doble registro" ya documentado para que no truene al
    // abrirla desde Eventos/Reservations) — "Explorar" en cambio es un TAB
    // DENTRO del stack raíz de cada rol (Home/GroupHome/TalentHome), no una
    // ruta del stack raíz en sí. navigate('Explorar', params) a secas
    // nunca encontraba esa ruta desde aquí y no hacía NADA — ni error, ni
    // navegación — para NINGUNA categoría, con o sin resultados. Hay que
    // apuntar primero a la pantalla raíz del rol y anidar el tab+params.
    const rootScreen = role === 'group' ? 'GroupHome' : role === 'talent' ? 'TalentHome' : 'Home';
    navigation.navigate(rootScreen, {
      screen: 'Explorar',
      params: {
        eventId: eventId ?? null,
        eventDate: eventDate ?? null,
        eventAddress: eventAddress ?? null,
        categoryGenres: genres,
        categoryLabel: label,
      },
    });
  };

  const pick = (cat: ProviderCategory) => {
    // Categorías con un solo género (Solista, DJ, Comida, MC, Comediante)
    // no necesitan un paso intermedio — van directo como siempre.
    if (cat.genres.length <= 1) { goToExplorar(cat.genres, t(cat.labelKey)); return; }
    setExpanded(cat);
  };

  if (expanded) {
    return (
      <View style={{ flex: 1, backgroundColor: COLORS.bg }}>
        <SafeAreaView edges={['top']} style={s.header}>
          <Pressable onPress={() => setExpanded(null)} hitSlop={8}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>{expanded.emoji} {t(expanded.labelKey)}</Text>
          <View style={{ width: 20 }} />
        </SafeAreaView>

        <ScrollView contentContainerStyle={s.body}>
          <Text style={s.sectionSub}>{t('eventCategoryPicker.pickGenreSubtitle', 'Elige el género exacto, o busca todos los de esta categoría.')}</Text>

          <Pressable style={s.genreRow} onPress={() => goToExplorar(expanded.genres, t(expanded.labelKey))}>
            <Text style={[s.genreRowText, { fontFamily: FONTS.bodySemiBold, color: COLORS.green }]}>
              Todos los de {t(expanded.labelKey)}
            </Text>
          </Pressable>

          {expanded.genres.map(g => {
            // null = todavia no se sabe (no se marca nada y no se miente).
            const sinOferta = genreCounts != null && genreCounts[g] === 0;
            return (
              <Pressable
                key={g}
                style={[s.genreRow, sinOferta && s.cardSoon]}
                onPress={() => goToExplorar([g], g)}
              >
                <View style={{ flex: 1 }}>
                  <Text style={[s.genreRowText, sinOferta && s.cardLabelSoon]}>{g}</Text>
                  {sinOferta && (
                    <Text style={s.genreRowSoonNote}>{t('eventCategoryPicker.noProvidersYet')}</Text>
                  )}
                </View>
                <Check size={16} color={COLORS.muted2} />
              </Pressable>
            );
          })}
        </ScrollView>
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: COLORS.bg }}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable onPress={() => navigation.goBack()} hitSlop={8}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>{t('eventCategoryPicker.title')}</Text>
        <View style={{ width: 20 }} />
      </SafeAreaView>

      <ScrollView contentContainerStyle={s.body}>
        {!!eventId && (
          <View style={s.eventBanner}>
            <Text style={s.eventBannerText}>
              {t('eventCategoryPicker.addingToEvent', {
                date: eventDate
                  ? new Date(eventDate + 'T12:00:00').toLocaleDateString(dateLocale, { day: 'numeric', month: 'long' })
                  : '—',
                address: eventAddress ?? '',
              })}
            </Text>
          </View>
        )}

        <Text style={s.sectionSub}>{t('eventCategoryPicker.subtitle')}</Text>

        <View style={s.grid}>
          {CATEGORY_OPTIONS.map(cat => {
            // null = todavía no se sabe (no se marca nada y no se miente).
            const sinOferta = counts != null && counts[cat.key] === 0;
            return (
              <Pressable key={cat.key} style={[s.card, sinOferta && s.cardSoon]} onPress={() => pick(cat)}>
                <Text style={[s.cardEmoji, sinOferta && s.cardEmojiSoon]}>{cat.emoji}</Text>
                <Text style={[s.cardLabel, sinOferta && s.cardLabelSoon]}>{t(cat.labelKey)}</Text>
                {sinOferta && (
                  <Text style={s.cardSoonNote}>{t('eventCategoryPicker.noProvidersYet')}</Text>
                )}
              </Pressable>
            );
          })}
        </View>
      </ScrollView>
    </View>
  );
}

const s = StyleSheet.create({
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingBottom: 12,
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  body: { padding: SPACING.xl, gap: 16, paddingBottom: 60 },
  eventBanner: {
    backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    borderRadius: RADIUS.lg, padding: 14,
  },
  eventBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, lineHeight: 19 },
  sectionSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  card: {
    width: '47%', backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, paddingVertical: 22, alignItems: 'center', gap: 8,
  },
  cardEmoji: { fontSize: 28 },
  // Categoría sin proveedores todavía: se atenúa y se rotula, pero SIGUE
  // siendo tocable — el cliente puede entrar y ver el estado vacío del
  // Explorador, y la categoría no desaparece porque Daricefy aún crece.
  cardSoon:       { borderStyle: 'dashed', opacity: 0.8 },
  cardEmojiSoon:  { opacity: 0.5 },
  cardLabelSoon:  { color: COLORS.muted2 },
  cardSoonNote: {
    fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted,
    textAlign: 'center', marginTop: 2,
  },
  cardLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, textAlign: 'center' },
  genreRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 14, paddingHorizontal: 16,
  },
  genreRowText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text },
  genreRowSoonNote: { fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted, marginTop: 2 },
});
