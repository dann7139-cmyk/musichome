/**
 * PhotoViewerModal — visor de foto a pantalla completa.
 * Se cierra con la X o tocando cualquier parte de la pantalla.
 * Usado por: ClientProfileModal (grupo ve foto del cliente) y
 * GroupDetailScreen (cliente ve foto del grupo).
 */
import React from 'react';
import { Image, Modal, Pressable, StyleSheet } from 'react-native';
import { X } from 'lucide-react-native';

interface Props {
  uri:     string | null;   // null = cerrado
  onClose: () => void;
}

export default function PhotoViewerModal({ uri, onClose }: Props) {
  if (!uri) return null;
  return (
    <Modal visible={!!uri} transparent animationType="fade" onRequestClose={onClose}>
      <Pressable style={s.overlay} onPress={onClose}>
        <Image source={{ uri }} style={s.photo} resizeMode="contain" />
        <Pressable style={s.closeX} onPress={onClose} hitSlop={12}>
          <X size={20} color="#fff" />
        </Pressable>
      </Pressable>
    </Modal>
  );
}

const s = StyleSheet.create({
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.96)', alignItems: 'center', justifyContent: 'center' },
  photo:   { width: '100%', height: '80%' },
  closeX: {
    position: 'absolute', top: 54, right: 18,
    width: 38, height: 38, borderRadius: 19,
    backgroundColor: 'rgba(255,255,255,0.12)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.25)',
    alignItems: 'center', justifyContent: 'center',
  },
});
