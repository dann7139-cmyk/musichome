/**
 * ScrollPicker — Selector tipo tambor (drum roll) para hora/minutos.
 * Se usa en TimePickerModal.
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { COLORS, FONTS } from '../../config/theme';

const ITEM_H  = 54;  // altura de cada ítem
const VISIBLE = 5;   // ítems visibles (el del medio es el seleccionado)

interface Props {
  items:         string[];
  selectedIndex: number;
  onSelect:      (index: number) => void;
  width?:        number;
}

export default function ScrollPicker({ items, selectedIndex, onSelect, width = 90 }: Props) {
  const ref            = useRef<ScrollView>(null);
  const [current, setCurrent] = useState(selectedIndex);

  // true mientras el usuario tiene el dedo en la pantalla
  const isUserScrolling = useRef(false);
  // true mientras nosotros hacemos scrollTo programático
  const isSnapping      = useRef(false);
  // timer para debounce al final del scroll
  const snapTimer       = useRef<ReturnType<typeof setTimeout> | null>(null);

  // ── Scroll inicial al ítem correcto (solo cuando NO hay interacción) ──
  useEffect(() => {
    if (isUserScrolling.current || isSnapping.current) return;
    const t = setTimeout(() => {
      ref.current?.scrollTo({ y: selectedIndex * ITEM_H, animated: false });
      setCurrent(selectedIndex);
    }, 80);
    return () => clearTimeout(t);
  }, [selectedIndex]);

  // ── Snap manual al ítem más cercano ──────────────────────────────────
  const snapToIndex = useCallback((rawY: number) => {
    const idx = Math.max(0, Math.min(Math.round(rawY / ITEM_H), items.length - 1));
    setCurrent(idx);
    onSelect(idx);
    isSnapping.current = true;
    ref.current?.scrollTo({ y: idx * ITEM_H, animated: true });
    // Resetear flag después de que termine la animación (~300 ms)
    setTimeout(() => { isSnapping.current = false; }, 400);
  }, [items.length, onSelect]);

  // ── Feedback visual en tiempo real ───────────────────────────────────
  const handleScroll = useCallback((e: any) => {
    if (!isUserScrolling.current) return;
    const y   = e.nativeEvent.contentOffset.y;
    const idx = Math.max(0, Math.min(Math.round(y / ITEM_H), items.length - 1));
    setCurrent(idx);
  }, [items.length]);

  // ── El usuario empieza a arrastrar ───────────────────────────────────
  const handleScrollBegin = useCallback(() => {
    isUserScrolling.current = true;
    if (snapTimer.current) { clearTimeout(snapTimer.current); snapTimer.current = null; }
  }, []);

  // ── El usuario soltó o terminó la inercia ────────────────────────────
  const handleScrollEnd = useCallback((e: any) => {
    // Ignorar eventos generados por nuestro propio scrollTo
    if (isSnapping.current) return;

    if (snapTimer.current) clearTimeout(snapTimer.current);
    const y = e.nativeEvent.contentOffset.y;

    // Pequeño delay: si tanto onScrollEndDrag como onMomentumScrollEnd se
    // disparan, ganará el último (con la posición más precisa).
    snapTimer.current = setTimeout(() => {
      isUserScrolling.current = false;
      snapToIndex(y);
      snapTimer.current = null;
    }, 50);
  }, [snapToIndex]);

  return (
    <View style={[s.root, { width, height: ITEM_H * VISIBLE }]}>
      {/* Caja de selección (centro) */}
      <View style={[s.selBox, { top: ITEM_H * 2, height: ITEM_H }]} pointerEvents="none" />

      <ScrollView
        ref={ref}
        showsVerticalScrollIndicator={false}
        decelerationRate="fast"
        scrollEventThrottle={16}
        contentContainerStyle={{ paddingVertical: ITEM_H * 2 }}
        onScrollBeginDrag={handleScrollBegin}
        onScroll={handleScroll}
        onMomentumScrollEnd={handleScrollEnd}
        onScrollEndDrag={handleScrollEnd}
      >
        {items.map((item, i) => {
          const dist     = Math.abs(i - current);
          const opacity  = dist === 0 ? 1 : dist === 1 ? 0.45 : 0.18;
          const fontSize = dist === 0 ? 26 : dist === 1 ? 18 : 14;
          return (
            <View key={i} style={{ height: ITEM_H, justifyContent: 'center', alignItems: 'center' }}>
              <Text style={[s.item, { opacity, fontSize, fontFamily: dist === 0 ? FONTS.bodySemiBold : FONTS.body }]}>
                {item}
              </Text>
            </View>
          );
        })}
      </ScrollView>
    </View>
  );
}

const s = StyleSheet.create({
  root: { overflow: 'hidden', position: 'relative' },
  selBox: {
    position: 'absolute', left: 6, right: 6,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: 12,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)',
    zIndex: 0,
  },
  item: { color: COLORS.text, textAlign: 'center' },
});
