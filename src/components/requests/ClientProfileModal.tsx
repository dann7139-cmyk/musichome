/**
 * ClientProfileModal — perfil PÚBLICO del cliente para el grupo.
 *
 * Consume get_client_public_profile (sql/435): nombre, foto, ciudad,
 * rating como cliente y antigüedad. SIN teléfono/email — garantizado
 * por construcción en el RPC (regla anti-robo de contacto: el contacto
 * es solo vía la app).
 */
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Image,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { X } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import PhotoViewerModal from '../ui/PhotoViewerModal';

interface ClientPublicProfile {
  ok: boolean;
  full_name: string | null;
  avatar_url: string | null;
  city: string | null;
  rating: number | null;
  reviews_count: number;
  member_since: string | null;
}

interface ClientReview {
  review_id: string;
  rating: number;
  comment: string | null;
  created_at: string;
  group_name: string;
  group_photo: string | null;
}

interface Props {
  clientId: string | null;   // null = cerrado
  onClose:  () => void;
}

export default function ClientProfileModal({ clientId, onClose }: Props) {
  const [profile,   setProfile]   = useState<ClientPublicProfile | null>(null);
  const [loading,   setLoading]   = useState(false);
  const [photoOpen, setPhotoOpen] = useState(false);

  const [reviews, setReviews] = useState<ClientReview[]>([]);

  useEffect(() => {
    if (!clientId) { setProfile(null); setReviews([]); return; }
    let cancelled = false;
    setLoading(true);
    supabase
      .rpc('get_client_public_profile', { p_client_id: clientId })
      .then(({ data }) => {
        if (cancelled) return;
        setProfile(data?.ok ? (data as ClientPublicProfile) : null);
        setLoading(false);
      });
    // Reseñas de otros grupos hacia este cliente (sql/436) — si el RPC
    // aún no existe en prod, la sección simplemente no se muestra
    supabase
      .rpc('get_client_public_reviews', { p_client_id: clientId, p_limit: 10 })
      .then(({ data, error }) => {
        if (!cancelled && !error && Array.isArray(data)) setReviews(data as ClientReview[]);
      });
    return () => { cancelled = true; };
  }, [clientId]);

  const memberSince = profile?.member_since
    ? new Date(profile.member_since).toLocaleDateString('es-MX', { month: 'long', year: 'numeric' })
    : null;

  return (
    <Modal visible={!!clientId} transparent animationType="slide" onRequestClose={onClose}>
      <View style={s.overlay}>
        <View style={s.sheet}>
          <View style={s.header}>
            <Text style={s.headerTitle}>Perfil del cliente</Text>
            <Pressable style={s.closeBtn} onPress={onClose}>
              <X size={18} color={COLORS.text} />
            </Pressable>
          </View>

          {loading && (
            <View style={s.loadingWrap}>
              <ActivityIndicator color={COLORS.green} />
            </View>
          )}

          {!loading && !profile && (
            <View style={s.loadingWrap}>
              <Text style={s.emptyTx}>No se pudo cargar el perfil.</Text>
            </View>
          )}

          {!loading && profile && (
            <View style={s.bodyWrap}>
              {profile.avatar_url
                ? (
                  <Pressable onPress={() => setPhotoOpen(true)} hitSlop={6}>
                    <Image source={{ uri: profile.avatar_url }} style={s.avatar} />
                    <Text style={s.tapHint}>Toca para ampliar</Text>
                  </Pressable>
                )
                : (
                  <View style={s.avatarPlaceholder}>
                    <Text style={s.avatarInitial}>
                      {(profile.full_name ?? '?').charAt(0).toUpperCase()}
                    </Text>
                  </View>
                )
              }
              <Text style={s.name}>{profile.full_name ?? 'Cliente'}</Text>

              {profile.rating != null ? (
                <Text style={s.rating}>
                  ⭐ {profile.rating} <Text style={s.ratingSub}>({profile.reviews_count} reseña{profile.reviews_count === 1 ? '' : 's'} como cliente)</Text>
                </Text>
              ) : (
                <Text style={s.ratingSub}>Sin reseñas todavía</Text>
              )}

              {profile.city ? <Text style={s.metaTx}>📍 {profile.city}</Text> : null}
              {memberSince ? <Text style={s.metaTx}>Miembro desde {memberSince}</Text> : null}

              {/* Reseñas chicas de otros grupos, deslizables */}
              {reviews.length > 0 && (
                <View style={s.reviewsWrap}>
                  <Text style={s.reviewsTitle}>Lo que dicen otros grupos</Text>
                  <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8, paddingHorizontal: 2 }}>
                    {reviews.map(rv => (
                      <View key={rv.review_id} style={s.reviewCard}>
                        <View style={s.reviewTop}>
                          {rv.group_photo
                            ? <Image source={{ uri: rv.group_photo }} style={s.reviewAvatar} />
                            : (
                              <View style={s.reviewAvatarPh}>
                                <Text style={s.reviewAvatarInitial}>
                                  {(rv.group_name ?? '?').charAt(0).toUpperCase()}
                                </Text>
                              </View>
                            )
                          }
                          <Text style={s.reviewGroupName} numberOfLines={1}>{rv.group_name}</Text>
                          <Text style={s.reviewStars}>⭐ {rv.rating}</Text>
                        </View>
                        {rv.comment ? (
                          <Text style={s.reviewComment} numberOfLines={3}>{rv.comment}</Text>
                        ) : (
                          <Text style={[s.reviewComment, { color: COLORS.muted }]}>Sin comentario</Text>
                        )}
                      </View>
                    ))}
                  </ScrollView>
                </View>
              )}

              <View style={s.contactNote}>
                <Text style={s.contactNoteTx}>🔒 El contacto con el cliente es solo vía la app</Text>
              </View>
            </View>
          )}

          <Pressable style={s.closeFullBtn} onPress={onClose}>
            <Text style={s.closeFullBtnTx}>Cerrar</Text>
          </Pressable>
        </View>
      </View>

      <PhotoViewerModal
        uri={photoOpen ? (profile?.avatar_url ?? null) : null}
        onClose={() => setPhotoOpen(false)}
      />
    </Modal>
  );
}

const s = StyleSheet.create({
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.75)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card,
    borderTopLeftRadius: 24, borderTopRightRadius: 24,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingBottom: 32,
  },

  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 16,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  headerTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  closeBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },

  loadingWrap: { paddingVertical: 48, alignItems: 'center' },
  emptyTx:     { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  bodyWrap: { alignItems: 'center', paddingHorizontal: SPACING.xl, paddingTop: 24, gap: 6 },
  avatar:            { width: 76, height: 76, borderRadius: 38, marginBottom: 6 },
  avatarPlaceholder: {
    width: 76, height: 76, borderRadius: 38, marginBottom: 6,
    backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center',
  },
  avatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 30, color: COLORS.green },
  tapHint:       { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'center', marginTop: 4 },
  name:      { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text },
  rating:    { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  ratingSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  metaTx:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  reviewsWrap:  { alignSelf: 'stretch', marginTop: 16, gap: 8 },
  reviewsTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  reviewCard: {
    width: 220,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 10, gap: 6,
  },
  reviewTop:           { flexDirection: 'row', alignItems: 'center', gap: 6 },
  reviewAvatar:        { width: 22, height: 22, borderRadius: 11 },
  reviewAvatarPh:      { width: 22, height: 22, borderRadius: 11, backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center' },
  reviewAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  reviewGroupName:     { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.text, flex: 1 },
  reviewStars:         { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.text },
  reviewComment:       { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 16 },

  contactNote: {
    marginTop: 14,
    backgroundColor: 'rgba(255,255,255,0.03)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
  },
  contactNoteTx: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },

  closeFullBtn: {
    marginHorizontal: SPACING.xl, marginTop: 20,
    backgroundColor: COLORS.bg,
    borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.lg, paddingVertical: 13,
    alignItems: 'center',
  },
  closeFullBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
});
