/**
 * GroupQrScreen — código QR del perfil público del grupo (petición real,
 * 2026-09-18: "estaría bien que cada grupo pueda descargar un QR para que
 * lo comparta, por si lo quiere descargar y si quieren lo imprimen en
 * grande"). El QR apunta al mismo link que ya restauramos en "Compartir"
 * (https://www.daricefy.com/grupos/[id]) — cualquiera que lo escanee cae
 * directo al perfil público en la web, sin necesidad de tener la app.
 *
 * Descargar/compartir usa el MISMO patrón ya probado en TicketScreen.tsx:
 * captureRef (react-native-view-shot) sobre una tarjeta oculta renderizada
 * a alta resolución (para que se vea bien impresa en grande), + MediaLibrary
 * para guardar en el carrete del celular.
 */
import React, { useRef, useState } from 'react';
import { ActivityIndicator, Alert, Share, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, Download, Share2 } from 'lucide-react-native';
import { Pressable } from 'react-native';
import QRCode from 'react-native-qrcode-svg';
import { captureRef } from 'react-native-view-shot';
import * as MediaLibrary from 'expo-media-library';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// Tamaño de exportación en px — suficiente para imprimirse en grande
// (aprox. 10×12cm a 300dpi) sin verse pixeleado.
const EXPORT_W = 1000;
const EXPORT_H = 1250;

export default function GroupQrScreen({ route, navigation }: any) {
  const group = route?.params?.group ?? {};
  const groupUrl = group?.id ? `https://www.daricefy.com/grupos/${group.id}` : 'https://www.daricefy.com';

  const exportRef = useRef<View>(null);
  const [saving, setSaving] = useState(false);
  const [sharing, setSharing] = useState(false);

  const handleDownload = async () => {
    setSaving(true);
    try {
      const { status } = await MediaLibrary.requestPermissionsAsync();
      if (status !== 'granted') {
        Alert.alert('Falta permiso', 'Necesitamos permiso para guardar la imagen en tu galería.');
        return;
      }
      const uri = await captureRef(exportRef, {
        format: 'png', quality: 1, width: EXPORT_W, height: EXPORT_H,
      } as any);
      await MediaLibrary.saveToLibraryAsync(uri);
      Alert.alert('Guardado', 'Tu código QR se guardó en la galería — ya lo puedes imprimir en grande.');
    } catch {
      Alert.alert('No se pudo guardar', 'Intenta de nuevo.');
    } finally {
      setSaving(false);
    }
  };

  const handleShare = async () => {
    setSharing(true);
    try {
      const uri = await captureRef(exportRef, { format: 'png', quality: 1 });
      await Share.share({ url: uri, message: `Escanea para ver a ${group?.name ?? 'mi grupo'} en Daricefy 🎵\n${groupUrl}` });
    } catch {
      // usuario canceló, o no se pudo — sin alerta, mismo criterio que el resto de la app
    } finally {
      setSharing(false);
    }
  };

  return (
    <View style={s.container}>
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.title}>Mi código QR</Text>
          <View style={{ width: 36 }} />
        </View>

        <View style={s.body}>
          <Text style={s.hint}>
            Cualquiera que escanee este código cae directo a tu perfil público en Daricefy — pégalo en tus flyers, tarjetas o redes.
          </Text>

          {/* Vista previa en pantalla */}
          <View style={s.previewCard}>
            <QRCode value={groupUrl} size={200} backgroundColor={COLORS.text} color={COLORS.bg} />
            <Text style={s.previewName} numberOfLines={1}>{group?.name ?? 'Mi grupo'}</Text>
            <Text style={s.previewBrand}>🎵 Daricefy</Text>
          </View>

          <View style={s.actions}>
            <Pressable style={[s.actionBtn, s.actionBtnPrimary]} onPress={handleDownload} disabled={saving}>
              {saving ? <ActivityIndicator size="small" color={COLORS.bg} /> : <Download size={16} color={COLORS.bg} />}
              <Text style={s.actionBtnTextPrimary}>{saving ? 'Guardando…' : 'Descargar'}</Text>
            </Pressable>
            <Pressable style={s.actionBtn} onPress={handleShare} disabled={sharing}>
              {sharing ? <ActivityIndicator size="small" color={COLORS.text} /> : <Share2 size={16} color={COLORS.text} />}
              <Text style={s.actionBtnText}>{sharing ? '…' : 'Compartir'}</Text>
            </Pressable>
          </View>
        </View>

        {/* 🖼️ Tarjeta oculta en alta resolución — captureRef la lee para
            exportar; nunca se ve en pantalla (top muy negativo). */}
        <View style={s.exportWrap} pointerEvents="none">
          <View ref={exportRef} collapsable={false} style={s.exportCard}>
            <View style={s.exportQrBox}>
              <QRCode value={groupUrl} size={EXPORT_W * 0.62} backgroundColor="#fff" color="#000" />
            </View>
            <Text style={s.exportName} numberOfLines={1}>{group?.name ?? 'Mi grupo'}</Text>
            <Text style={s.exportSub}>Escanéame en Daricefy 🎵</Text>
          </View>
        </View>
      </SafeAreaView>
    </View>
  );
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
  },
  backBtn: {
    width: 36, height: 36, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  title: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },

  body: { flex: 1, paddingHorizontal: SPACING.xl, alignItems: 'center', gap: 24 },
  hint: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', lineHeight: 19, marginTop: 8 },

  previewCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 24, alignItems: 'center', gap: 10,
  },
  previewName: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, maxWidth: 220 },
  previewBrand: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green },

  actions: { flexDirection: 'row', gap: 10, width: '100%' },
  actionBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    paddingVertical: 14, borderRadius: RADIUS.lg,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  actionBtnPrimary: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  actionBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  actionBtnTextPrimary: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  exportWrap: { position: 'absolute', top: -6000, left: 0 },
  exportCard: {
    width: EXPORT_W, height: EXPORT_H, backgroundColor: '#fff',
    alignItems: 'center', justifyContent: 'center', gap: 24,
  },
  exportQrBox: { padding: 24, backgroundColor: '#fff' },
  exportName: { fontFamily: FONTS.title, fontSize: 34, color: '#111', maxWidth: EXPORT_W * 0.85, textAlign: 'center' },
  exportSub: { fontFamily: FONTS.bodyMedium, fontSize: 20, color: COLORS.green },
});
