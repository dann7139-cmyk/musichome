import * as ImagePicker from 'expo-image-picker';
import VideoPlayer from '../../components/ui/VideoPlayer';
import {
  Calendar,
  Check,
  ChevronDown,
  ChevronUp,
  Edit2,
  Image as ImageIcon,
  Megaphone,
  MessageSquare,
  Play,
  Plus,
  Trash2,
  Video as VideoIcon,
  X,
} from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Modal,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  View,
} from 'react-native';
import { Calendar as RNCalendar } from 'react-native-calendars';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';

// ─── Types ────────────────────────────────────────────────────────────────────

interface Promotion {
  id: string;
  title: string;
  subtitle: string | null;
  tag: string;
  button_text: string;
  link_type: 'none' | 'group' | 'talent';
  link_id: string | null;
  is_active: boolean;
  order_index: number;
  starts_at: string | null;
  ends_at: string | null;
  media_url: string | null;
  media_type: 'none' | 'image' | 'video';
  media_offset: number;
}

interface AdMessage {
  id: string;
  sender_name: string | null;
  sender_phone: string | null;
  message: string;
  is_read: boolean;
  created_at: string;
  promotion_id: string | null;
  promo_title?: string;
}

type Tab = 'anuncios' | 'mensajes';

const EMPTY_FORM = {
  title: '',
  subtitle: '',
  tag: 'PUBLICIDAD',
  button_text: 'Contactar',
  link_type: 'none' as 'none' | 'group' | 'talent',
  link_id: '',
  is_active: true,
  order_index: '0',
  starts_date: '',
  ends_date: '',
  media_url: '',
  media_type: 'none' as 'none' | 'image' | 'video',
  media_offset: 50,
};

const fmtDate = (iso: string | null): string => {
  if (!iso) return '';
  return new Date(iso).toLocaleDateString('es-MX', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
};

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AdminPromotionsScreen() {
  const [tab, setTab]               = useState<Tab>('anuncios');
  const [promos, setPromos]         = useState<Promotion[]>([]);
  const [messages, setMessages]     = useState<AdMessage[]>([]);
  const [unreadCount, setUnreadCount] = useState(0);
  const [loading, setLoading]       = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [showModal, setShowModal]   = useState(false);
  const [editPromo, setEditPromo]   = useState<Promotion | null>(null);
  const [saving, setSaving]         = useState(false);
  const [form, setForm]             = useState(EMPTY_FORM);
  const [mediaUploading, setMediaUploading] = useState(false);

  // Inline calendar (no nested modal)
  const [calendarFor, setCalendarFor] = useState<'starts' | 'ends' | null>(null);

  useEffect(() => { fetchAll(); }, []);

  const fetchAll = async () => {
    setLoading(true);
    await Promise.all([fetchPromos(), fetchMessages()]);
    setLoading(false);
  };

  const fetchPromos = async () => {
    const { data } = await supabase
      .from('promotions')
      .select('*')
      .order('order_index', { ascending: true });
    if (data) setPromos(data as Promotion[]);
  };

  const fetchMessages = async () => {
    const { data } = await supabase
      .from('ad_messages')
      .select('id, sender_name, sender_phone, message, is_read, created_at, promotion_id')
      .order('created_at', { ascending: false });
    if (!data) return;

    const promoIds = [...new Set(data.map((m: any) => m.promotion_id).filter(Boolean))];
    let promoTitles: Record<string, string> = {};
    if (promoIds.length > 0) {
      const { data: pt } = await supabase.from('promotions').select('id, title').in('id', promoIds);
      (pt ?? []).forEach((p: any) => { promoTitles[p.id] = p.title; });
    }

    const list: AdMessage[] = data.map((m: any) => ({
      ...m, promo_title: m.promotion_id ? promoTitles[m.promotion_id] ?? null : null,
    }));
    setMessages(list);
    setUnreadCount(list.filter(m => !m.is_read).length);
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchAll();
    setRefreshing(false);
  };

  const openCreate = () => {
    setEditPromo(null);
    setForm(EMPTY_FORM);
    setCalendarFor(null);
    setShowModal(true);
  };

  const openEdit = (p: Promotion) => {
    setEditPromo(p);
    setCalendarFor(null);
    setForm({
      title:        p.title,
      subtitle:     p.subtitle ?? '',
      tag:          p.tag,
      button_text:  p.button_text,
      link_type:    p.link_type,
      link_id:      p.link_id ?? '',
      is_active:    p.is_active,
      order_index:  String(p.order_index),
      starts_date:  p.starts_at ? p.starts_at.split('T')[0] : '',
      ends_date:    p.ends_at   ? p.ends_at.split('T')[0]   : '',
      media_url:    p.media_url ?? '',
      media_type:   p.media_type ?? 'none',
      media_offset: p.media_offset ?? 50,
    });
    setShowModal(true);
  };

  const handleSave = async () => {
    if (!form.title.trim()) { Alert.alert('Error', 'El título es obligatorio'); return; }
    setSaving(true);
    const payload = {
      title:        form.title.trim(),
      subtitle:     form.subtitle.trim() || null,
      emoji:        '📢',
      tag:          form.tag.trim() || 'PUBLICIDAD',
      button_text:  form.button_text.trim() || 'Contactar',
      link_type:    form.link_type,
      link_id:      form.link_type !== 'none' && form.link_id.trim() ? form.link_id.trim() : null,
      is_active:    form.is_active,
      order_index:  parseInt(form.order_index) || 0,
      starts_at:    form.starts_date ? `${form.starts_date}T00:00:00.000Z` : null,
      ends_at:      form.ends_date   ? `${form.ends_date}T23:59:59.999Z`   : null,
      media_url:    form.media_url || null,
      media_type:   form.media_url ? form.media_type : 'none',
      media_offset: form.media_offset,
    };
    if (editPromo) {
      await supabase.from('promotions').update(payload).eq('id', editPromo.id);
    } else {
      await supabase.from('promotions').insert([payload]);
    }
    setSaving(false);
    setShowModal(false);
    fetchPromos();
  };

  const handleDelete = (p: Promotion) => {
    Alert.alert('Eliminar anuncio', `¿Eliminar "${p.title}"?`, [
      { text: 'Cancelar', style: 'cancel' },
      { text: 'Eliminar', style: 'destructive', onPress: async () => {
        await supabase.from('promotions').delete().eq('id', p.id);
        fetchPromos();
      }},
    ]);
  };

  const markRead = async (msg: AdMessage) => {
    if (msg.is_read) return;
    await supabase.from('ad_messages').update({ is_read: true }).eq('id', msg.id);
    setMessages(prev => prev.map(m => m.id === msg.id ? { ...m, is_read: true } : m));
    setUnreadCount(prev => Math.max(0, prev - 1));
  };

  // ── Media ────────────────────────────────────────────────────────────────────

  const pickMedia = async (type: 'images' | 'videos') => {
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: type, allowsEditing: false, quality: 0.85,
    });
    if (result.canceled || !result.assets[0]) return;

    const asset     = result.assets[0];
    const isVideo   = type === 'videos';
    const ext       = isVideo ? 'mp4' : 'jpg';
    const contentType = isVideo ? 'video/mp4' : 'image/jpeg';
    const filename  = `promo_${Date.now()}.${ext}`;

    setMediaUploading(true);
    try {
      const ab = await fetch(asset.uri).then(r => r.arrayBuffer());
      const { error } = await supabase.storage
        .from('promotions-media')
        .upload(filename, ab, { contentType, upsert: true });
      if (error) throw error;
      const { data } = supabase.storage.from('promotions-media').getPublicUrl(filename);
      setForm(f => ({ ...f, media_url: data.publicUrl, media_type: isVideo ? 'video' : 'image', media_offset: 50 }));
    } catch {
      Alert.alert('Error', 'No se pudo subir el archivo.');
    }
    setMediaUploading(false);
  };

  // ── Calendar day press ───────────────────────────────────────────────────────

  const onDayPress = (day: any) => {
    if (calendarFor === 'starts') {
      setForm(f => ({ ...f, starts_date: day.dateString }));
    } else if (calendarFor === 'ends') {
      setForm(f => ({ ...f, ends_date: day.dateString }));
    }
    setCalendarFor(null);
  };

  const calendarMarked = (() => {
    const m: Record<string, any> = {};
    const d = calendarFor === 'starts' ? form.starts_date : form.ends_date;
    if (d) m[d] = { selected: true, selectedColor: COLORS.green };
    return m;
  })();

  // ── Media preview helper ─────────────────────────────────────────────────────

  const MEDIA_H   = 200;  // container height (preview in form)
  const MEDIA_SRC = 340;  // source height (tall enough to shift)
  const offsetTranslate = (offset: number) => -(offset / 100) * (MEDIA_SRC - MEDIA_H);

  // ─────────────────────────────────────────────────────────────────────────────

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* Header */}
        <View style={s.header}>
          <Megaphone size={20} color={COLORS.green} />
          <Text style={s.headerTitle}>Publicidad</Text>
          {tab === 'anuncios' && (
            <Pressable style={s.addBtn} onPress={openCreate}>
              <Plus size={18} color={COLORS.green} />
            </Pressable>
          )}
        </View>

        {/* Tabs */}
        <View style={s.tabRow}>
          {(['anuncios', 'mensajes'] as Tab[]).map(t => (
            <Pressable key={t} style={[s.tabBtn, tab === t && s.tabBtnActive]} onPress={() => setTab(t)}>
              {t === 'anuncios'
                ? <Megaphone size={13} color={tab === t ? COLORS.green : COLORS.muted} />
                : <MessageSquare size={13} color={tab === t ? COLORS.green : COLORS.muted} />
              }
              <Text style={[s.tabText, tab === t && s.tabTextActive]}>
                {t === 'anuncios' ? 'Anuncios' : 'Mensajes'}
              </Text>
              {t === 'mensajes' && unreadCount > 0 && (
                <View style={s.badge}><Text style={s.badgeText}>{unreadCount}</Text></View>
              )}
            </Pressable>
          ))}
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={s.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* ── ANUNCIOS ── */}
          {tab === 'anuncios' && (
            promos.length === 0 ? (
              <View style={s.empty}>
                <Text style={{ fontSize: 40, marginBottom: 14 }}>📢</Text>
                <Text style={s.emptyTitle}>Sin anuncios</Text>
                <Text style={s.emptyHint}>Crea tu primer anuncio para mostrarlo en Explorar</Text>
                <View style={{ marginTop: 16, width: '100%' }}>
                  <Button label="+ Crear anuncio" onPress={openCreate} />
                </View>
              </View>
            ) : (
              promos.map(p => (
                <View key={p.id} style={[s.promoCard, !p.is_active && s.promoCardInactive]}>
                  {/* Media thumbnail */}
                  {p.media_type !== 'none' && p.media_url && (
                    <View style={s.cardMediaThumb}>
                      {p.media_type === 'video' ? (
                        <View style={s.cardVideoThumb}>
                          <Play size={22} color={COLORS.text} />
                          <Text style={s.cardVideoLabel}>VIDEO</Text>
                        </View>
                      ) : (
                        <Image source={{ uri: p.media_url }} style={s.cardMediaImg} />
                      )}
                    </View>
                  )}
                  {/* Text row */}
                  <View style={s.previewRow}>
                    <View style={{ flex: 1 }}>
                      <Text style={s.promoTag}>{p.tag}</Text>
                      <Text style={s.promoTitle}>{p.title}</Text>
                      {p.subtitle && <Text style={s.promoSub}>{p.subtitle}</Text>}
                    </View>
                    <View style={s.promoCTA}><Text style={s.promoCTAText}>{p.button_text}</Text></View>
                  </View>
                  {/* Dates */}
                  {(p.starts_at || p.ends_at) && (
                    <View style={s.datesRow}>
                      {p.starts_at && <Text style={s.dateChip}>▶ {fmtDate(p.starts_at)}</Text>}
                      {p.ends_at   && <Text style={[s.dateChip, { color: COLORS.muted }]}>⏹ {fmtDate(p.ends_at)}</Text>}
                    </View>
                  )}
                  {/* Meta + actions */}
                  <View style={s.promoMeta}>
                    <View style={[s.statusDot, { backgroundColor: p.is_active ? COLORS.green : COLORS.muted }]} />
                    <Text style={s.promoMetaText}>
                      {p.is_active ? 'Activo' : 'Inactivo'}
                      {p.link_type !== 'none' ? ` · ${p.link_type}` : ''}
                      {p.order_index !== 0 ? ` · pos. ${p.order_index}` : ''}
                    </Text>
                    <View style={s.promoActions}>
                      <Pressable style={s.actionBtn} onPress={() => openEdit(p)}>
                        <Edit2 size={14} color={COLORS.green} />
                      </Pressable>
                      <Pressable style={s.actionBtn} onPress={() => handleDelete(p)}>
                        <Trash2 size={14} color={COLORS.red} />
                      </Pressable>
                    </View>
                  </View>
                </View>
              ))
            )
          )}

          {/* ── MENSAJES ── */}
          {tab === 'mensajes' && (
            messages.length === 0 ? (
              <View style={s.empty}>
                <Text style={{ fontSize: 40, marginBottom: 14 }}>💬</Text>
                <Text style={s.emptyTitle}>Sin mensajes</Text>
                <Text style={s.emptyHint}>Aquí aparecerán los mensajes de contacto de los anuncios</Text>
              </View>
            ) : (
              messages.map(msg => (
                <Pressable key={msg.id} style={[s.msgCard, !msg.is_read && s.msgCardUnread]} onPress={() => markRead(msg)}>
                  {!msg.is_read && <View style={s.unreadDot} />}
                  <View style={s.msgTopRow}>
                    <Text style={s.msgSender}>{msg.sender_name ?? 'Desconocido'}</Text>
                    <Text style={s.msgDate}>
                      {new Date(msg.created_at).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}
                    </Text>
                  </View>
                  {msg.sender_phone && <Text style={s.msgPhone}>📞 {msg.sender_phone}</Text>}
                  {msg.promo_title  && <Text style={s.msgPromo}>📢 {msg.promo_title}</Text>}
                  <Text style={s.msgBody}>"{msg.message}"</Text>
                  {msg.is_read && (
                    <View style={s.readChip}>
                      <Check size={10} color={COLORS.muted} />
                      <Text style={s.readText}>Leído</Text>
                    </View>
                  )}
                </Pressable>
              ))
            )
          )}
        </ScrollView>
      </SafeAreaView>

      {/* ── MODAL: Crear/Editar ── */}
      <Modal visible={showModal} transparent animationType="slide">
        <View style={s.modalOverlay}>
          <View style={s.modal}>
            <View style={s.modalHeader}>
              <Text style={s.modalTitle}>{editPromo ? 'Editar anuncio' : 'Nuevo anuncio'}</Text>
              <Pressable onPress={() => setShowModal(false)}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>

            <ScrollView showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled">

              {/* ── Media ── */}
              <Text style={s.fieldLabel}>Imagen o Video</Text>
              {form.media_url ? (
                <View>
                  {/* Preview con offset aplicado */}
                  <View style={s.mediaPreview}>
                    {form.media_type === 'video' ? (
                      <VideoPlayer
                        uri={form.media_url}
                        style={[s.mediaContent, { transform: [{ translateY: offsetTranslate(form.media_offset) }] }]}
                        contentFit="cover"
                        muted
                        loop
                      />
                    ) : (
                      <Image
                        source={{ uri: form.media_url }}
                        style={[s.mediaContent, { transform: [{ translateY: offsetTranslate(form.media_offset) }] }]}
                      />
                    )}
                    <Pressable style={s.mediaRemoveBtn} onPress={() => setForm(f => ({ ...f, media_url: '', media_type: 'none', media_offset: 50 }))}>
                      <X size={16} color={COLORS.text} />
                    </Pressable>
                  </View>

                  {/* Controles de posición */}
                  <View style={s.offsetSection}>
                    <Text style={s.offsetLabel}>Posición vertical</Text>
                    <View style={s.offsetRow}>
                      <Pressable
                        style={s.offsetBtn}
                        onPress={() => setForm(f => ({ ...f, media_offset: Math.max(0, f.media_offset - 10) }))}
                      >
                        <ChevronUp size={18} color={COLORS.green} />
                        <Text style={s.offsetBtnText}>Arriba</Text>
                      </Pressable>
                      <View style={s.offsetPresets}>
                        {[{ l: 'Inicio', v: 0 }, { l: 'Centro', v: 50 }, { l: 'Final', v: 100 }].map(p => (
                          <Pressable
                            key={p.v}
                            style={[s.offsetPreset, form.media_offset === p.v && s.offsetPresetActive]}
                            onPress={() => setForm(f => ({ ...f, media_offset: p.v }))}
                          >
                            <Text style={[s.offsetPresetText, form.media_offset === p.v && s.offsetPresetTextActive]}>
                              {p.l}
                            </Text>
                          </Pressable>
                        ))}
                      </View>
                      <Pressable
                        style={s.offsetBtn}
                        onPress={() => setForm(f => ({ ...f, media_offset: Math.min(100, f.media_offset + 10) }))}
                      >
                        <ChevronDown size={18} color={COLORS.green} />
                        <Text style={s.offsetBtnText}>Abajo</Text>
                      </Pressable>
                    </View>
                  </View>
                </View>
              ) : mediaUploading ? (
                <View style={s.mediaPickerBtn}>
                  <ActivityIndicator color={COLORS.green} />
                  <Text style={s.mediaPickerText}>Subiendo...</Text>
                </View>
              ) : (
                <View style={s.mediaPickerRow}>
                  <Pressable style={[s.mediaPickerBtn, { flex: 1 }]} onPress={() => pickMedia('images')}>
                    <ImageIcon size={18} color={COLORS.muted2} />
                    <Text style={s.mediaPickerText}>Imagen</Text>
                  </Pressable>
                  <Pressable style={[s.mediaPickerBtn, { flex: 1 }]} onPress={() => pickMedia('videos')}>
                    <VideoIcon size={18} color={COLORS.muted2} />
                    <Text style={s.mediaPickerText}>Video</Text>
                  </Pressable>
                </View>
              )}

              {/* ── Fechas (solo día, sin hora) ── */}
              <View style={s.datesSection}>
                {/* Inicio */}
                <View style={{ flex: 1 }}>
                  <Text style={s.fieldLabel}>Inicio (opcional)</Text>
                  <Pressable
                    style={[s.datePicker, calendarFor === 'starts' && s.datePickerOpen]}
                    onPress={() => setCalendarFor(calendarFor === 'starts' ? null : 'starts')}
                  >
                    <Calendar size={13} color={form.starts_date ? COLORS.green : COLORS.muted} />
                    <Text style={[s.datePickerText, !form.starts_date && { color: COLORS.muted }]}>
                      {form.starts_date
                        ? new Date(form.starts_date).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' })
                        : 'Sin fecha'}
                    </Text>
                    {form.starts_date
                      ? <Pressable onPress={(e) => { e.stopPropagation(); setForm(f => ({ ...f, starts_date: '' })); }}>
                          <X size={12} color={COLORS.muted} />
                        </Pressable>
                      : <ChevronDown size={12} color={COLORS.muted} />
                    }
                  </Pressable>
                </View>

                <Text style={s.dateSep}>→</Text>

                {/* Fin */}
                <View style={{ flex: 1 }}>
                  <Text style={s.fieldLabel}>Fin (opcional)</Text>
                  <Pressable
                    style={[s.datePicker, calendarFor === 'ends' && s.datePickerOpen]}
                    onPress={() => setCalendarFor(calendarFor === 'ends' ? null : 'ends')}
                  >
                    <Calendar size={13} color={form.ends_date ? COLORS.muted2 : COLORS.muted} />
                    <Text style={[s.datePickerText, !form.ends_date && { color: COLORS.muted }]}>
                      {form.ends_date
                        ? new Date(form.ends_date).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' })
                        : 'Sin fecha'}
                    </Text>
                    {form.ends_date
                      ? <Pressable onPress={(e) => { e.stopPropagation(); setForm(f => ({ ...f, ends_date: '' })); }}>
                          <X size={12} color={COLORS.muted} />
                        </Pressable>
                      : <ChevronDown size={12} color={COLORS.muted} />
                    }
                  </Pressable>
                </View>
              </View>

              {/* Calendario inline — se expande bajo los botones */}
              {calendarFor && (
                <View style={s.inlineCal}>
                  <RNCalendar
                    onDayPress={onDayPress}
                    markedDates={calendarMarked}
                    minDate={new Date().toISOString().split('T')[0]}
                    theme={{
                      calendarBackground:           COLORS.bg,
                      textSectionTitleColor:         COLORS.muted2,
                      dayTextColor:                  COLORS.text,
                      todayTextColor:                COLORS.green,
                      selectedDayBackgroundColor:    COLORS.green,
                      selectedDayTextColor:          '#000',
                      monthTextColor:                COLORS.text,
                      arrowColor:                    COLORS.green,
                      textDisabledColor:             COLORS.border,
                    }}
                  />
                </View>
              )}

              {/* ── Campos básicos ── */}
              <View style={{ marginTop: 8 }}>
                <Input
                  label="Título *"
                  placeholder="Ej: Llega a miles de clientes"
                  value={form.title}
                  onChangeText={v => setForm(f => ({ ...f, title: v }))}
                />
                <Input
                  label="Subtítulo"
                  placeholder="Descripción breve"
                  value={form.subtitle}
                  onChangeText={v => setForm(f => ({ ...f, subtitle: v }))}
                />
              </View>
              <View style={s.formRow}>
                <View style={{ flex: 1 }}>
                  <Input
                    label="Texto del botón"
                    placeholder="Contactar"
                    value={form.button_text}
                    onChangeText={v => setForm(f => ({ ...f, button_text: v }))}
                  />
                </View>
                <View style={{ flex: 1 }}>
                  <Input
                    label="Posición (0=primero)"
                    placeholder="0"
                    value={form.order_index}
                    onChangeText={v => setForm(f => ({ ...f, order_index: v }))}
                    keyboardType="numeric"
                  />
                </View>
              </View>
              <Input
                label="Etiqueta"
                placeholder="PUBLICIDAD"
                value={form.tag}
                onChangeText={v => setForm(f => ({ ...f, tag: v }))}
              />

              {/* Enlace */}
              <Text style={s.fieldLabel}>Enlace del anuncio</Text>
              <View style={s.linkTypeRow}>
                {(['none', 'group', 'talent'] as const).map(lt => (
                  <Pressable
                    key={lt}
                    style={[s.linkTypeBtn, form.link_type === lt && s.linkTypeBtnActive]}
                    onPress={() => setForm(f => ({ ...f, link_type: lt, link_id: '' }))}
                  >
                    <Text style={[s.linkTypeText, form.link_type === lt && s.linkTypeTextActive]}>
                      {lt === 'none' ? 'Ninguno' : lt === 'group' ? 'Grupo' : 'Artista'}
                    </Text>
                  </Pressable>
                ))}
              </View>
              {form.link_type !== 'none' && (
                <Input
                  label={`ID del ${form.link_type === 'group' ? 'grupo' : 'artista'} (UUID)`}
                  placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
                  value={form.link_id}
                  onChangeText={v => setForm(f => ({ ...f, link_id: v }))}
                />
              )}

              {/* Activo */}
              <View style={s.toggleRow}>
                <Text style={s.fieldLabel}>Anuncio activo</Text>
                <Switch
                  value={form.is_active}
                  onValueChange={v => setForm(f => ({ ...f, is_active: v }))}
                  trackColor={{ false: COLORS.border, true: COLORS.green }}
                  thumbColor={COLORS.text}
                />
              </View>

              <View style={{ gap: 10, marginTop: 8, marginBottom: 24 }}>
                <Button label="Guardar anuncio" onPress={handleSave} loading={saving} />
                <Button label="Cancelar" onPress={() => setShowModal(false)} variant="ghost" />
              </View>
            </ScrollView>
          </View>
        </View>
      </Modal>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: SPACING.xl, paddingTop: 14, paddingBottom: 12,
  },
  headerTitle: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, flex: 1 },
  addBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  tabRow: { flexDirection: 'row', gap: 8, paddingHorizontal: SPACING.xl, marginBottom: 14 },
  tabBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    paddingVertical: 10, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  tabBtnActive:  { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  tabText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  tabTextActive: { color: COLORS.green },
  badge: { backgroundColor: COLORS.green, borderRadius: RADIUS.full, paddingHorizontal: 6, paddingVertical: 1 },
  badgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.bg },
  list: { paddingHorizontal: SPACING.xl, paddingBottom: 32, gap: 12 },
  empty: { alignItems: 'center', paddingTop: 60 },
  emptyTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginBottom: 8 },
  emptyHint: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },

  // Promo card
  promoCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden',
  },
  promoCardInactive: { opacity: 0.5 },
  cardMediaThumb: { width: '100%', height: 110, backgroundColor: COLORS.bg },
  cardMediaImg: { width: '100%', height: '100%', resizeMode: 'cover' },
  cardVideoThumb: {
    flex: 1, backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center', gap: 6,
  },
  cardVideoLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, letterSpacing: 1 },
  previewRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    padding: SPACING.md, paddingBottom: 6,
  },
  promoTag:   { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.green, letterSpacing: 1.2, marginBottom: 1 },
  promoTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  promoSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  promoCTA: { paddingHorizontal: 10, paddingVertical: 6, borderRadius: RADIUS.md, backgroundColor: COLORS.green },
  promoCTAText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: '#000' },
  datesRow: { flexDirection: 'row', gap: 10, paddingHorizontal: SPACING.md, paddingBottom: 6 },
  dateChip: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green },
  promoMeta: {
    flexDirection: 'row', alignItems: 'center', gap: 7,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingTop: 8, paddingBottom: 8, paddingHorizontal: SPACING.md,
  },
  statusDot: { width: 7, height: 7, borderRadius: 4 },
  promoMetaText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, flex: 1 },
  promoActions: { flexDirection: 'row', gap: 4 },
  actionBtn: {
    width: 32, height: 32, borderRadius: 8,
    backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center',
  },

  // Messages
  msgCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, position: 'relative',
  },
  msgCardUnread: { borderColor: COLORS.green + '60' },
  unreadDot: {
    position: 'absolute', top: 14, right: 14,
    width: 9, height: 9, borderRadius: 5, backgroundColor: COLORS.green,
  },
  msgTopRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 },
  msgSender: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  msgDate:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  msgPhone:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginBottom: 4 },
  msgPromo:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 6 },
  msgBody: {
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    lineHeight: 22, fontStyle: 'italic', marginBottom: 6,
  },
  readChip: { flexDirection: 'row', alignItems: 'center', gap: 4, alignSelf: 'flex-end' },
  readText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },

  // Modal
  modalOverlay: { flex: 1, backgroundColor: COLORS.overlay, justifyContent: 'flex-end' },
  modal: {
    backgroundColor: COLORS.card2, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, maxHeight: '95%',
  },
  modalHeader: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 18,
  },
  modalTitle: { fontFamily: FONTS.title, fontSize: 19, color: COLORS.text },

  // Media
  mediaPickerRow: { flexDirection: 'row', gap: 10, marginBottom: 4 },
  mediaPickerBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, paddingVertical: 14,
  },
  mediaPickerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  mediaPreview: {
    height: 200, borderRadius: RADIUS.md, overflow: 'hidden',
    backgroundColor: COLORS.card, marginBottom: 0, position: 'relative',
  },
  mediaContent: { width: '100%', height: 340, resizeMode: 'cover' },
  mediaRemoveBtn: {
    position: 'absolute', top: 8, right: 8,
    width: 28, height: 28, borderRadius: 14,
    backgroundColor: 'rgba(0,0,0,0.65)', alignItems: 'center', justifyContent: 'center',
  },

  // Offset controls
  offsetSection: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.md, marginBottom: 4,
  },
  offsetLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, marginBottom: 10, textAlign: 'center', letterSpacing: 0.8 },
  offsetRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  offsetBtn: { alignItems: 'center', gap: 2, paddingHorizontal: 4 },
  offsetBtnText: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.green },
  offsetPresets: { flex: 1, flexDirection: 'row', gap: 6 },
  offsetPreset: {
    flex: 1, alignItems: 'center', paddingVertical: 7, borderRadius: RADIUS.full,
    backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border,
  },
  offsetPresetActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  offsetPresetText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted },
  offsetPresetTextActive: { color: COLORS.green },

  // Dates (inline)
  datesSection: { flexDirection: 'row', alignItems: 'flex-start', gap: 8, marginBottom: 4 },
  dateSep: { fontFamily: FONTS.body, fontSize: 16, color: COLORS.muted, marginTop: 32 },
  datePicker: {
    flexDirection: 'row', alignItems: 'center', gap: 7,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 10, paddingVertical: 10,
  },
  datePickerOpen: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  datePickerText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.text, flex: 1 },
  inlineCal: {
    borderRadius: RADIUS.md, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.border, marginBottom: 12,
  },

  // Form
  formRow: { flexDirection: 'row', gap: 12 },
  fieldLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 6, marginTop: 4 },
  linkTypeRow: { flexDirection: 'row', gap: 8, marginBottom: 12 },
  linkTypeBtn: {
    flex: 1, alignItems: 'center', paddingVertical: 9, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  linkTypeBtnActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  linkTypeText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted },
  linkTypeTextActive: { color: COLORS.green },
  toggleRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginBottom: 16, paddingVertical: 8,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
});
