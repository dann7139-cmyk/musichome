"use client";

import { useEffect, useRef } from "react";

export interface GroupLocation {
  group_id: string;
  lat: number;
  lng: number;
  city: string | null;
  status: string;
  last_seen: string;
  groups?: { name: string; city: string | null } | null;
}

interface Props {
  locations: GroupLocation[];
}

const STATUS_COLOR: Record<string, string> = {
  in_event: "#ef4444",
  active:   "#00E676",
  offline:  "#6b6b6b",
};

const STATUS_LABEL: Record<string, string> = {
  in_event: "En evento",
  active:   "Activo",
  offline:  "Sin conexión",
};

export default function AdminMap({ locations }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef       = useRef<any>(null);

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;

    // ── Inyectar CSS de Leaflet desde CDN ────────────────────────────────
    if (!document.getElementById("leaflet-css")) {
      const link = document.createElement("link");
      link.id   = "leaflet-css";
      link.rel  = "stylesheet";
      link.href = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css";
      document.head.appendChild(link);
    }

    // ── Cargar Leaflet JS desde CDN ──────────────────────────────────────
    const loadLeaflet = () => {
      if ((window as any).L) {
        initMap();
        return;
      }
      const script = document.createElement("script");
      script.src = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js";
      script.onload = initMap;
      document.head.appendChild(script);
    };

    const initMap = () => {
      const L = (window as any).L;
      if (!containerRef.current || mapRef.current) return;

      // Centrar en México
      const map = L.map(containerRef.current, {
        center:          [23.6345, -102.5528],
        zoom:            5,
        zoomControl:     true,
        scrollWheelZoom: true,
      });

      // Tiles OpenStreetMap (gratuito, sin API key)
      L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        attribution: "© OpenStreetMap contributors",
        maxZoom:     18,
      }).addTo(map);

      // Marcadores
      locations.forEach((loc) => {
        const color = STATUS_COLOR[loc.status] ?? "#6b6b6b";
        const name  = (loc.groups as any)?.name ?? "Grupo";
        const city  = loc.city ?? (loc.groups as any)?.city ?? "—";
        const since = new Date(loc.last_seen).toLocaleString("es-MX", {
          dateStyle: "short", timeStyle: "short",
        });

        const circle = L.circleMarker([loc.lat, loc.lng], {
          radius:      9,
          fillColor:   color,
          color:       "#040404",
          weight:      2,
          opacity:     1,
          fillOpacity: 0.92,
        });

        circle.bindPopup(`
          <div style="font-family:system-ui;min-width:160px">
            <p style="font-weight:700;margin:0 0 4px">${name}</p>
            <p style="margin:0;color:#666;font-size:12px">📍 ${city}</p>
            <p style="margin:4px 0 0;font-size:11px">
              <span style="background:${color}22;color:${color};padding:2px 6px;border-radius:4px;font-weight:600">
                ${STATUS_LABEL[loc.status] ?? loc.status}
              </span>
            </p>
            <p style="margin:4px 0 0;color:#999;font-size:10px">Última vez: ${since}</p>
          </div>
        `);

        circle.addTo(map);
      });

      // Auto-fit si hay ubicaciones
      if (locations.length > 0) {
        const bounds = L.latLngBounds(locations.map(l => [l.lat, l.lng]));
        map.fitBounds(bounds, { padding: [40, 40], maxZoom: 10 });
      }

      mapRef.current = map;
    };

    loadLeaflet();

    return () => {
      if (mapRef.current) {
        mapRef.current.remove();
        mapRef.current = null;
      }
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Actualizar marcadores si cambian las locations
  useEffect(() => {
    // El mapa ya se inicializa con las locations del primer render.
    // Si se quiere hot-reload de markers, habría que limpiar y re-añadir.
    // Por ahora el reload completo es suficiente para el admin.
  }, [locations]);

  return (
    <div>
      {/* Leyenda */}
      <div className="mb-3 flex flex-wrap gap-4">
        {Object.entries(STATUS_LABEL).map(([key, label]) => (
          <div key={key} className="flex items-center gap-1.5 text-xs text-brand-muted">
            <span
              className="h-3 w-3 rounded-full border border-black/20"
              style={{ backgroundColor: STATUS_COLOR[key] }}
            />
            {label}
          </div>
        ))}
        <span className="text-xs text-brand-muted">· {locations.length} grupos en mapa</span>
      </div>

      {/* Mapa */}
      <div
        ref={containerRef}
        className="h-[420px] w-full overflow-hidden rounded-2xl border border-brand-border"
        style={{ background: "#1a1a1a" }}
      />

      {locations.length === 0 && (
        <div className="flex h-[420px] -mt-[420px] items-center justify-center rounded-2xl">
          <p className="text-sm text-brand-muted">
            Ningún grupo ha compartido su ubicación todavía.
          </p>
        </div>
      )}
    </div>
  );
}
