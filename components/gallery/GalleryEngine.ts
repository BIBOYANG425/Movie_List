import * as THREE from 'three';
import { Tier, RankedItem } from '../../types';
import {
  GalleryDiagnostics,
  GalleryEngineCallbacks,
  GalleryEngineOptions,
  GalleryMode,
} from './galleryTypes';
import {
  buildCorridorLayout,
  roomIndexAtZ,
  CorridorLayout,
  CaseSlot,
  ARCH_DEPTH,
  CASE_H,
  CASE_W,
  EYE_Y,
  ROOM_TAIL,
  WALL_X,
} from './galleryLayout';
import { computeWantedTextures, tmdbImageAtSize } from './textureWindow';

// Scene constants. Spike-tunable values live here so the phone pass can
// adjust them in one place (technique: reference keeps a constants block).
const HALL_BG = '#050505';
const FOG_NEAR = 8;
const FOG_FAR = 26;
const CAMERA_NEAR = 0.1;
const CAMERA_FAR = 60;
const LOOK_AHEAD = 4;
const WHEEL_GAIN = 0.0024;
const CLICK_MAX_TRAVEL = 7; // px — under this, a pointerup is a tap
const SNAP_IDLE_MS = 150;
const MAX_DELTA = 0.05; // s — background tabs can't produce a giant step
const FOCUS_IN_DURATION = 0.46;
const FOCUS_OUT_DURATION = 0.34;
const REDUCED_FOCUS_DURATION = 0.08;
const INSPECT_DISTANCE = 1.35;
const IDLE_LIFT = 0.014;
const IDLE_PITCH = THREE.MathUtils.degToRad(0.28);
const IDLE_YAW = THREE.MathUtils.degToRad(0.48);
const IDLE_ROLL = THREE.MathUtils.degToRad(0.22);
const TEXTURE_WINDOW_THROTTLE_MS = 200;
const LOAD_CONCURRENCY = 4;
const DESKTOP_PLACARD_MAX = 620;
const DESKTOP_PLACARD_RATIO = 0.41;
const MOBILE_SHEET_OFFSET = 0.22; // fraction of viewport height

const clamp = THREE.MathUtils.clamp;
const damp = THREE.MathUtils.damp;

function fovForWidth(width: number): number {
  if (width >= 920) return 42;
  if (width >= 600) return 45;
  return 48;
}

type CaseRuntime = {
  slot: CaseSlot;
  item: RankedItem;
  group: THREE.Group; // positioned at the slot; flight animates this
  swayGroup: THREE.Group; // idle sway wrapper, centered on the case
  poster: THREE.Mesh<THREE.PlaneGeometry, THREE.MeshBasicMaterial>;
  glow: THREE.Sprite;
  pickProxy: THREE.Mesh;
  texture: THREE.Texture | null;
  textureUrl: string | null;
  loadFailed: boolean;
};

export class GalleryEngine {
  private canvas: HTMLCanvasElement;
  private callbacks: GalleryEngineCallbacks;
  private tierLabels: Record<Tier, string>;
  private reducedMotion: boolean;

  private renderer!: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera!: THREE.PerspectiveCamera;
  private corridorGroup = new THREE.Group();
  private roomGroup = new THREE.Group();
  private caseGroup = new THREE.Group();
  private bounceLight!: THREE.PointLight;

  private layout: CorridorLayout = {
    rooms: [],
    slots: [],
    totalLength: 0,
    walkStops: [],
  };
  private cases: CaseRuntime[] = [];
  private caseByItemId = new Map<string, CaseRuntime>();
  private pickTargets: THREE.Object3D[] = [];

  private raycaster = new THREE.Raycaster();
  private pointer = new THREE.Vector2(10, 10);
  private mode: GalleryMode = 'hall';
  private walk = 0; // fractional flat slot index
  private targetWalk = 0;
  private focusIndex = 0;
  private lastRoomIndex = -1;
  private focusProgress = 0;
  private selectedIndex: number | null = null;
  private hoverIndex: number | null = null;

  private pointerDown = false;
  private pointerId: number | null = null;
  private pointerStart = { x: 0, y: 0 };
  private pointerLast = { x: 0, y: 0 };
  private pointerTravel = 0;
  private lastInputTime = 0;

  private glowTexture!: THREE.Texture;
  private frameMaterial!: THREE.MeshBasicMaterial;
  private placeholderMaterial!: THREE.MeshBasicMaterial;
  private wallMaterial!: THREE.MeshStandardMaterial;
  private floorMaterial!: THREE.MeshStandardMaterial;
  private archGlowMaterial!: THREE.MeshBasicMaterial;
  private dimQuad!: THREE.Mesh<THREE.PlaneGeometry, THREE.MeshBasicMaterial>;
  private backdropPlane: THREE.Mesh<
    THREE.PlaneGeometry,
    THREE.MeshBasicMaterial
  > | null = null;
  private backdropTexture: THREE.Texture | null = null;
  private backdropForItemId: string | null = null;
  private inspectPosterTexture: THREE.Texture | null = null;

  private loadQueue: CaseRuntime[] = [];
  private loadsInFlight = 0;
  private lastWindowUpdate = 0;
  private textureLoader = new THREE.TextureLoader();

  private animationFrame = 0;
  private lastTimestamp = 0;
  private resizeObserver!: ResizeObserver;
  private contextLossCount = 0;
  private isDisposed = false;
  private crossfadeCallback: (() => void) | null = null;

  constructor(canvas: HTMLCanvasElement, options: GalleryEngineOptions) {
    this.canvas = canvas;
    this.callbacks = options.callbacks;
    this.tierLabels = options.tierLabels;
    this.reducedMotion = options.reducedMotion;
    this.textureLoader.setCrossOrigin('anonymous');

    try {
      this.renderer = new THREE.WebGLRenderer({
        canvas,
        antialias: canvas.clientWidth >= 760,
        powerPreference: 'high-performance',
      });
    } catch {
      this.callbacks.onFatal('init-failed');
      return;
    }
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.03;

    this.camera = new THREE.PerspectiveCamera(
      fovForWidth(canvas.clientWidth || 1024),
      1,
      CAMERA_NEAR,
      CAMERA_FAR,
    );

    this.setupScene();
    this.setItems(options.items);
    this.bindEvents();

    this.resizeObserver = new ResizeObserver(this.handleResize);
    this.resizeObserver.observe(canvas);
    this.handleResize();
    this.animate();

    if (import.meta.env.DEV) {
      (window as unknown as Record<string, unknown>).__SPOOL_GALLERY__ = {
        diagnostics: () => this.getDiagnostics(),
      };
    }
  }

  // ── Scene ────────────────────────────────────────────────────────────────

  private setupScene() {
    this.scene.background = new THREE.Color(HALL_BG);
    this.scene.fog = new THREE.Fog(HALL_BG, FOG_NEAR, FOG_FAR);

    // Exactly 4 global lights; the per-case "glow" is emissive fakery.
    this.scene.add(new THREE.HemisphereLight('#20242c', '#000000', 0.35));
    const key = new THREE.DirectionalLight('#fff2e0', 0.5);
    key.position.set(1.5, 6, 4);
    this.scene.add(key);
    const rim = new THREE.DirectionalLight('#8fa3bf', 0.3);
    rim.position.set(0, 2.5, -12);
    this.scene.add(rim);
    this.bounceLight = new THREE.PointLight('#d7b072', 0.25, 18, 2);
    this.bounceLight.position.set(0, 1.2, 0);
    this.scene.add(this.bounceLight);

    // Shared materials — draw-call and memory discipline.
    this.wallMaterial = new THREE.MeshStandardMaterial({
      color: '#0a0a0c',
      roughness: 1,
      metalness: 0,
    });
    this.floorMaterial = new THREE.MeshStandardMaterial({
      color: '#08080a',
      roughness: 0.96,
      metalness: 0,
    });
    this.archGlowMaterial = new THREE.MeshBasicMaterial({
      color: '#e9dfc8',
      transparent: true,
      opacity: 0.16,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.frameMaterial = new THREE.MeshBasicMaterial({ color: '#e8e0d0' });
    this.placeholderMaterial = new THREE.MeshBasicMaterial({
      color: '#101012',
    });
    this.glowTexture = this.makeGlowTexture();

    // Camera-attached dim quad for the inspect environment.
    const dimMaterial = new THREE.MeshBasicMaterial({
      color: '#000000',
      transparent: true,
      opacity: 0,
      depthTest: false,
      depthWrite: false,
    });
    this.dimQuad = new THREE.Mesh(new THREE.PlaneGeometry(40, 24), dimMaterial);
    this.dimQuad.renderOrder = 90;
    this.dimQuad.visible = false;
    this.camera.add(this.dimQuad);
    this.dimQuad.position.set(0, 0, -8);
    this.scene.add(this.camera);

    this.scene.add(this.corridorGroup);
    this.corridorGroup.add(this.roomGroup);
    this.corridorGroup.add(this.caseGroup);
  }

  private makeGlowTexture(): THREE.Texture {
    const size = 128;
    const canvas = document.createElement('canvas');
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext('2d')!;
    const gradient = ctx.createRadialGradient(
      size / 2,
      size / 2,
      4,
      size / 2,
      size / 2,
      size / 2,
    );
    gradient.addColorStop(0, 'rgba(233,223,200,0.85)');
    gradient.addColorStop(0.5, 'rgba(233,223,200,0.22)');
    gradient.addColorStop(1, 'rgba(233,223,200,0)');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, size, size);
    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    return texture;
  }

  private makeLabelTexture(text: string): THREE.CanvasTexture {
    const canvas = document.createElement('canvas');
    canvas.width = 512;
    canvas.height = 128;
    const ctx = canvas.getContext('2d')!;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = 'rgba(231,226,214,0.62)';
    ctx.font = '400 44px Georgia, "Times New Roman", serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    // letterspace by hand — canvas has no tracking control pre-2023 baseline
    const spaced = text.toUpperCase().split('').join('  ');
    ctx.fillText(spaced, canvas.width / 2, canvas.height / 2);
    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.anisotropy = Math.min(
      8,
      this.renderer.capabilities.getMaxAnisotropy(),
    );
    return texture;
  }

  private makeFallbackPosterTexture(item: RankedItem): THREE.CanvasTexture {
    const canvas = document.createElement('canvas');
    canvas.width = 342;
    canvas.height = 513;
    const ctx = canvas.getContext('2d')!;
    ctx.fillStyle = '#14141a';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.strokeStyle = 'rgba(233,223,200,0.28)';
    ctx.strokeRect(14, 14, canvas.width - 28, canvas.height - 28);
    ctx.fillStyle = 'rgba(233,223,200,0.82)';
    ctx.textAlign = 'center';
    ctx.font = 'italic 400 30px Georgia, serif';
    const words = item.title.split(' ');
    const lines: string[] = [];
    let line = '';
    words.forEach((word) => {
      const next = line ? `${line} ${word}` : word;
      if (ctx.measureText(next).width > canvas.width - 60 && line) {
        lines.push(line);
        line = word;
      } else {
        line = next;
      }
    });
    if (line) lines.push(line);
    const startY = canvas.height / 2 - ((lines.length - 1) * 38) / 2;
    lines.slice(0, 6).forEach((l, i) => {
      ctx.fillText(l, canvas.width / 2, startY + i * 38);
    });
    ctx.font = '400 22px Georgia, serif';
    ctx.fillStyle = 'rgba(233,223,200,0.45)';
    ctx.fillText(item.year, canvas.width / 2, canvas.height - 48);
    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    return texture;
  }

  // ── Corridor construction ────────────────────────────────────────────────

  setItems(items: RankedItem[]) {
    if (this.isDisposed) return;
    const previousFocusId =
      this.cases[this.focusIndex]?.item.id ?? null;

    // Tear down current corridor contents (textures keyed per case).
    this.cases.forEach((c) => this.disposeCaseTexture(c));
    this.caseGroup.clear();
    this.roomGroup.children.forEach((child) => {
      child.traverse((obj) => {
        if (obj instanceof THREE.Mesh) {
          obj.geometry.dispose();
          const material = obj.material as THREE.Material & {
            map?: THREE.Texture | null;
          };
          // Shared materials are disposed in dispose(); only label planes own
          // their material + texture.
          if (material.userData?.owned) {
            material.map?.dispose();
            material.dispose();
          }
        }
      });
    });
    this.roomGroup.clear();
    this.cases = [];
    this.caseByItemId.clear();
    this.pickTargets = [];
    this.loadQueue = [];

    const tiers = Object.values(Tier) as Tier[];
    this.layout = buildCorridorLayout(items, tiers);

    this.layout.rooms.forEach((room) => this.buildRoom(room));
    this.layout.slots.forEach((slot) => {
      const item = items.find((i) => i.id === slot.itemId)!;
      const runtime = this.buildCase(slot, item);
      this.cases.push(runtime);
      this.caseByItemId.set(item.id, runtime);
    });

    // Re-anchor the walk to the previously focused item when it survives.
    const anchor = previousFocusId
      ? this.cases.findIndex((c) => c.item.id === previousFocusId)
      : -1;
    const target = anchor >= 0 ? anchor : clamp(this.focusIndex, 0, Math.max(0, this.cases.length - 1));
    this.walk = target;
    this.targetWalk = target;
    this.focusIndex = target;
    this.lastRoomIndex = -1;
    this.updateTextureWindow(true);
    this.announceRoom();
  }

  private buildRoom(room: (typeof this.layout.rooms)[number]) {
    const length = room.startZ - room.endZ;
    const centerZ = (room.startZ + room.endZ) / 2;
    const wallGeometry = new THREE.PlaneGeometry(length, 4.2);

    const left = new THREE.Mesh(wallGeometry, this.wallMaterial);
    left.position.set(-WALL_X - 0.01, 2.1, centerZ);
    left.rotation.y = Math.PI / 2;
    this.roomGroup.add(left);

    const right = new THREE.Mesh(wallGeometry, this.wallMaterial);
    right.position.set(WALL_X + 0.01, 2.1, centerZ);
    right.rotation.y = -Math.PI / 2;
    this.roomGroup.add(right);

    const floor = new THREE.Mesh(
      new THREE.PlaneGeometry(WALL_X * 2 + 0.4, length + ARCH_DEPTH),
      this.floorMaterial,
    );
    floor.rotation.x = -Math.PI / 2;
    floor.position.set(0, 0, centerZ - ARCH_DEPTH / 2);
    this.roomGroup.add(floor);

    // End wall with archway: two side panels + lintel; warm glow behind.
    const archHalf = 0.75;
    const panelWidth = WALL_X - archHalf;
    const panelGeometry = new THREE.PlaneGeometry(panelWidth, 4.2);
    const leftPanel = new THREE.Mesh(panelGeometry, this.wallMaterial);
    leftPanel.position.set(-(archHalf + panelWidth / 2), 2.1, room.archwayZ);
    this.roomGroup.add(leftPanel);
    const rightPanel = new THREE.Mesh(panelGeometry, this.wallMaterial);
    rightPanel.position.set(archHalf + panelWidth / 2, 2.1, room.archwayZ);
    this.roomGroup.add(rightPanel);
    const lintel = new THREE.Mesh(
      new THREE.PlaneGeometry(archHalf * 2, 4.2 - 2.6),
      this.wallMaterial,
    );
    lintel.position.set(0, 2.6 + (4.2 - 2.6) / 2, room.archwayZ);
    this.roomGroup.add(lintel);

    const isLastRoom = room.roomIndex === this.layout.rooms.length - 1;
    if (!isLastRoom) {
      const glow = new THREE.Mesh(
        new THREE.PlaneGeometry(archHalf * 2, 2.6),
        this.archGlowMaterial,
      );
      glow.position.set(0, 1.3, room.archwayZ - 0.5);
      this.roomGroup.add(glow);
    }

    // Serif tier label high on the entry wall.
    const labelTexture = this.makeLabelTexture(
      `${room.tier} TIER`,
    );
    const labelMaterial = new THREE.MeshBasicMaterial({
      map: labelTexture,
      transparent: true,
      depthWrite: false,
    });
    labelMaterial.userData.owned = true;
    const label = new THREE.Mesh(
      new THREE.PlaneGeometry(1.6, 0.4),
      labelMaterial,
    );
    label.position.set(0, 3.1, room.labelZ - 0.4);
    this.roomGroup.add(label);
  }

  private buildCase(slot: CaseSlot, item: RankedItem): CaseRuntime {
    const group = new THREE.Group();
    group.position.set(slot.x, slot.y, slot.z);
    group.rotation.y = slot.yawY;
    group.scale.setScalar(slot.scale);

    const swayGroup = new THREE.Group();
    group.add(swayGroup);

    const poster = new THREE.Mesh(
      new THREE.PlaneGeometry(CASE_W, CASE_H),
      this.placeholderMaterial.clone(),
    );
    poster.material.userData.owned = true;
    swayGroup.add(poster);

    // Thin edge-light strips framing the poster (emissive fake).
    const stripThickness = 0.014;
    const stripDepth = 0.002;
    const horizontal = new THREE.PlaneGeometry(
      CASE_W + stripThickness * 2,
      stripThickness,
    );
    const vertical = new THREE.PlaneGeometry(
      stripThickness,
      CASE_H + stripThickness * 2,
    );
    const top = new THREE.Mesh(horizontal, this.frameMaterial);
    top.position.set(0, CASE_H / 2 + stripThickness / 2, stripDepth);
    const bottom = new THREE.Mesh(horizontal, this.frameMaterial);
    bottom.position.set(0, -CASE_H / 2 - stripThickness / 2, stripDepth);
    const leftStrip = new THREE.Mesh(vertical, this.frameMaterial);
    leftStrip.position.set(-CASE_W / 2 - stripThickness / 2, 0, stripDepth);
    const rightStrip = new THREE.Mesh(vertical, this.frameMaterial);
    rightStrip.position.set(CASE_W / 2 + stripThickness / 2, 0, stripDepth);
    swayGroup.add(top, bottom, leftStrip, rightStrip);

    const glow = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: this.glowTexture,
        transparent: true,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        opacity: slot.isTierAnchor ? 0.42 : 0.28,
      }),
    );
    glow.scale.setScalar(slot.isTierAnchor ? 2.0 : 1.45);
    glow.position.z = -0.03;
    swayGroup.add(glow);

    const pickProxy = new THREE.Mesh(
      new THREE.PlaneGeometry(CASE_W * 1.12, CASE_H * 1.12),
      new THREE.MeshBasicMaterial({
        transparent: true,
        opacity: 0,
        depthWrite: false,
      }),
    );
    pickProxy.material.userData.owned = true;
    pickProxy.position.z = 0.01;
    pickProxy.userData.flatIndex = slot.flatIndex;
    swayGroup.add(pickProxy);
    this.pickTargets.push(pickProxy);

    this.caseGroup.add(group);

    return {
      slot,
      item,
      group,
      swayGroup,
      poster: poster as CaseRuntime['poster'],
      glow,
      pickProxy,
      texture: null,
      textureUrl: null,
      loadFailed: false,
    };
  }

  // ── Texture management ───────────────────────────────────────────────────

  private prepareTexture(texture: THREE.Texture) {
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.anisotropy = Math.min(
      8,
      this.renderer.capabilities.getMaxAnisotropy(),
    );
    texture.generateMipmaps = true;
    texture.minFilter = THREE.LinearMipmapLinearFilter;
  }

  private disposeCaseTexture(runtime: CaseRuntime) {
    if (runtime.texture) {
      runtime.texture.dispose();
      runtime.texture = null;
      runtime.textureUrl = null;
    }
    runtime.poster.material.map = null;
    runtime.poster.material.color.set('#101012');
    runtime.poster.material.needsUpdate = true;
  }

  private updateTextureWindow(force = false) {
    const now = performance.now();
    if (!force && now - this.lastWindowUpdate < TEXTURE_WINDOW_THROTTLE_MS) {
      return;
    }
    this.lastWindowUpdate = now;
    if (this.cases.length === 0) return;

    const cameraZ = this.walkZ();
    const loaded = new Set<string>();
    this.cases.forEach((c) => {
      if (c.texture) loaded.add(c.item.id);
    });
    const { load, keep } = computeWantedTextures({
      slots: this.layout.slots,
      rooms: this.layout.rooms,
      cameraRoomIndex: roomIndexAtZ(this.layout, cameraZ),
      focusFlatIndex: this.focusIndex,
      loaded,
    });

    this.cases.forEach((runtime) => {
      const inspected = this.selectedIndex !== null &&
        this.cases[this.selectedIndex] === runtime;
      if (inspected) return; // inspected case is pinned
      if (keep.has(runtime.item.id)) {
        if (
          load.has(runtime.item.id) &&
          !runtime.texture &&
          !runtime.loadFailed &&
          !this.loadQueue.includes(runtime)
        ) {
          this.loadQueue.push(runtime);
        }
      } else if (runtime.texture) {
        this.disposeCaseTexture(runtime);
      }
    });
    this.pumpLoadQueue();
  }

  private pumpLoadQueue() {
    while (this.loadsInFlight < LOAD_CONCURRENCY && this.loadQueue.length > 0) {
      const runtime = this.loadQueue.shift()!;
      if (runtime.texture || runtime.loadFailed) continue;
      this.loadsInFlight += 1;
      const url = runtime.item.posterUrl
        ? tmdbImageAtSize(runtime.item.posterUrl, 'w342')
        : null;

      const applyTexture = (texture: THREE.Texture, sourceUrl: string | null) => {
        if (this.isDisposed) {
          texture.dispose();
          return;
        }
        this.prepareTexture(texture);
        runtime.texture = texture;
        runtime.textureUrl = sourceUrl;
        runtime.poster.material.map = texture;
        runtime.poster.material.color.set('#ffffff');
        runtime.poster.material.needsUpdate = true;
      };

      if (!url) {
        applyTexture(this.makeFallbackPosterTexture(runtime.item), null);
        this.loadsInFlight -= 1;
        continue;
      }

      this.textureLoader.load(
        url,
        (texture) => {
          applyTexture(texture, url);
          this.loadsInFlight -= 1;
          this.pumpLoadQueue();
        },
        undefined,
        () => {
          // Missing art never breaks a room: procedural typographic case.
          runtime.loadFailed = true;
          applyTexture(this.makeFallbackPosterTexture(runtime.item), null);
          this.loadsInFlight -= 1;
          this.pumpLoadQueue();
        },
      );
    }
  }

  // ── Input ────────────────────────────────────────────────────────────────

  private bindEvents() {
    this.canvas.addEventListener('wheel', this.handleWheel, {
      passive: false,
    });
    this.canvas.addEventListener('pointerdown', this.handlePointerDown);
    this.canvas.addEventListener('pointermove', this.handlePointerMove);
    this.canvas.addEventListener('pointerup', this.handlePointerUp);
    this.canvas.addEventListener('pointercancel', this.handlePointerCancel);
    this.canvas.addEventListener('keydown', this.handleKeyDown);
    this.canvas.addEventListener(
      'webglcontextlost',
      this.handleContextLost,
      false,
    );
    this.canvas.addEventListener(
      'webglcontextrestored',
      this.handleContextRestored,
      false,
    );
    window.addEventListener('blur', this.handleWindowBlur);
  }

  private handleWheel = (event: WheelEvent) => {
    if (this.mode !== 'hall') return;
    event.preventDefault();
    const dominant =
      Math.abs(event.deltaX) > Math.abs(event.deltaY)
        ? event.deltaX
        : event.deltaY;
    this.targetWalk = clamp(
      this.targetWalk + dominant * WHEEL_GAIN,
      0,
      Math.max(0, this.cases.length - 1),
    );
    this.lastInputTime = performance.now();
  };

  private handlePointerDown = (event: PointerEvent) => {
    if (this.mode !== 'hall') {
      // In inspect, a tap outside the placard returns to the wall; the
      // placard overlay stops propagation before it reaches the canvas.
      if (this.mode === 'inspect') this.closeInspect();
      return;
    }
    this.pointerDown = true;
    this.pointerId = event.pointerId;
    this.pointerStart = { x: event.clientX, y: event.clientY };
    this.pointerLast = { x: event.clientX, y: event.clientY };
    this.pointerTravel = 0;
    this.canvas.setPointerCapture(event.pointerId);
  };

  private handlePointerMove = (event: PointerEvent) => {
    this.updatePointer(event);
    if (this.mode !== 'hall') return;

    if (this.pointerDown && event.pointerId === this.pointerId) {
      const dx = event.clientX - this.pointerLast.x;
      const dy = event.clientY - this.pointerLast.y;
      this.pointerLast = { x: event.clientX, y: event.clientY };
      const dominant = Math.abs(dy) > Math.abs(dx) ? dy : dx;
      this.pointerTravel += Math.abs(dominant);
      this.targetWalk = clamp(
        this.targetWalk -
          dominant /
            Math.max(105, this.canvas.clientHeight * 0.11),
        0,
        Math.max(0, this.cases.length - 1),
      );
      this.lastInputTime = performance.now();
      return;
    }
    this.updateHover();
  };

  private handlePointerUp = (event: PointerEvent) => {
    if (event.pointerId !== this.pointerId) return;
    const wasClick = this.pointerTravel < CLICK_MAX_TRAVEL;
    this.pointerDown = false;
    this.pointerId = null;
    if (this.canvas.hasPointerCapture(event.pointerId)) {
      this.canvas.releasePointerCapture(event.pointerId);
    }
    if (this.mode === 'hall' && wasClick) {
      this.updatePointer(event);
      const hit = this.raycastCase();
      if (hit !== null) this.beginInspect(hit);
    }
  };

  private handlePointerCancel = (event: PointerEvent) => {
    if (event.pointerId !== this.pointerId) return;
    this.pointerDown = false;
    this.pointerId = null;
  };

  private handleWindowBlur = () => {
    this.pointerDown = false;
    this.pointerId = null;
  };

  private handleKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'Escape') {
      this.closeInspect();
      return;
    }
    if (this.mode !== 'hall') return;
    const forward = event.key === 'ArrowRight' || event.key === 'ArrowDown';
    const back = event.key === 'ArrowLeft' || event.key === 'ArrowUp';
    if (forward || back) {
      event.preventDefault();
      this.targetWalk = clamp(
        Math.round(this.targetWalk) + (forward ? 1 : -1),
        0,
        Math.max(0, this.cases.length - 1),
      );
      this.lastInputTime = performance.now() - 1000;
    } else if (event.key === 'Home') {
      event.preventDefault();
      this.targetWalk = 0;
    } else if (event.key === 'End') {
      event.preventDefault();
      this.targetWalk = Math.max(0, this.cases.length - 1);
    } else if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      this.beginInspect(this.focusIndex);
    }
  };

  private handleContextLost = (event: Event) => {
    event.preventDefault();
    cancelAnimationFrame(this.animationFrame);
    this.contextLossCount += 1;
    this.callbacks.onStatus('Display paused');
    if (this.contextLossCount > 1) {
      this.callbacks.onFatal('webgl-lost');
    }
  };

  private handleContextRestored = () => {
    if (this.isDisposed || this.contextLossCount > 1) return;
    try {
      // three re-uploads GPU resources lazily on next render.
      this.callbacks.onStatus('Display restored');
      this.lastTimestamp = performance.now();
      this.animate();
    } catch {
      this.callbacks.onFatal('webgl-lost');
    }
  };

  private updatePointer(event: PointerEvent) {
    const rect = this.canvas.getBoundingClientRect();
    this.pointer.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    this.pointer.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;
  }

  private raycastCase(): number | null {
    this.raycaster.setFromCamera(this.pointer, this.camera);
    const hit = this.raycaster.intersectObjects(this.pickTargets, false)[0];
    const index = hit?.object.userData.flatIndex;
    return typeof index === 'number' ? index : null;
  }

  private updateHover() {
    const hit = this.raycastCase();
    if (hit !== this.hoverIndex) {
      this.hoverIndex = hit;
      if (hit !== null) {
        const runtime = this.cases[hit];
        if (runtime) this.emitFocus(hit);
      }
    }
    this.canvas.style.cursor = hit === null ? 'grab' : 'pointer';
  }

  // ── Public controls ──────────────────────────────────────────────────────

  travelToTier(tier: Tier) {
    if (this.mode !== 'hall') return;
    const room = this.layout.rooms.find((r) => r.tier === tier);
    if (!room || room.slots.length === 0) return;
    const target = room.slots[0].flatIndex;
    if (this.reducedMotion) {
      // Crossfade handled by GalleryView (canvas opacity dip); we teleport.
      this.crossfadeCallback?.();
      this.walk = target;
      this.targetWalk = target;
    } else {
      this.targetWalk = target;
    }
    this.lastInputTime = performance.now() - 1000;
  }

  /** GalleryView registers a callback that runs a CSS crossfade on teleport. */
  onCrossfade(callback: (() => void) | null) {
    this.crossfadeCallback = callback;
  }

  inspect(itemId: string) {
    const runtime = this.caseByItemId.get(itemId);
    if (runtime) this.beginInspect(runtime.slot.flatIndex);
  }

  closeInspect() {
    if (this.mode !== 'inspect' && this.mode !== 'focusing') return;
    this.mode = 'returning';
    this.callbacks.onModeChange(
      'returning',
      this.selectedIndex !== null
        ? this.cases[this.selectedIndex].item.id
        : null,
    );
  }

  setBackdrop(itemId: string, url: string | null) {
    if (this.isDisposed) return;
    if (
      this.selectedIndex === null ||
      this.cases[this.selectedIndex].item.id !== itemId
    ) {
      return; // stale response for a case we already hung back
    }
    this.backdropForItemId = itemId;
    if (!url) return; // dim quad alone is the environment

    const load = new THREE.ImageLoader();
    load.setCrossOrigin('anonymous');
    load.load(
      url,
      (image) => {
        if (
          this.isDisposed ||
          this.backdropForItemId !== itemId ||
          this.selectedIndex === null
        ) {
          return;
        }
        // Blur + darken on an offscreen canvas — cheap, done once.
        const canvas = document.createElement('canvas');
        canvas.width = 512;
        canvas.height = Math.round(
          (image.height / image.width) * 512,
        ) || 288;
        const ctx = canvas.getContext('2d')!;
        ctx.filter = 'blur(14px) brightness(0.4)';
        ctx.drawImage(image, -24, -24, canvas.width + 48, canvas.height + 48);
        const texture = new THREE.CanvasTexture(canvas);
        texture.colorSpace = THREE.SRGBColorSpace;

        this.disposeBackdrop();
        this.backdropTexture = texture;
        const aspect = canvas.width / canvas.height;
        const height = 11;
        const plane = new THREE.Mesh(
          new THREE.PlaneGeometry(height * aspect, height),
          new THREE.MeshBasicMaterial({
            map: texture,
            transparent: true,
            opacity: 0,
            depthTest: false,
            depthWrite: false,
          }),
        );
        plane.renderOrder = 91; // above dim quad, below the case
        plane.position.set(0, 0, -7.5);
        this.camera.add(plane);
        this.backdropPlane = plane;
      },
      undefined,
      () => undefined, // missing backdrop: dim quad remains
    );
  }

  setReducedMotion(value: boolean) {
    this.reducedMotion = value;
  }

  // ── Inspect flight ───────────────────────────────────────────────────────

  private beginInspect(index: number) {
    if (this.mode !== 'hall' || this.cases.length === 0) return;
    const runtime = this.cases[clamp(index, 0, this.cases.length - 1)];
    if (!runtime) return;
    this.walk = runtime.slot.flatIndex;
    this.targetWalk = runtime.slot.flatIndex;
    this.focusIndex = runtime.slot.flatIndex;
    this.selectedIndex = runtime.slot.flatIndex;
    this.focusProgress = 0;
    this.mode = 'focusing';
    // Swap the inspected poster to the sharper w780 bucket.
    this.loadInspectPoster(runtime);
    this.emitFocus(this.focusIndex);
    this.callbacks.onModeChange('focusing', runtime.item.id);
    this.callbacks.onStatus(`Opening ${runtime.item.title}`);
  }

  private loadInspectPoster(runtime: CaseRuntime) {
    if (!runtime.item.posterUrl) return;
    const url = tmdbImageAtSize(runtime.item.posterUrl, 'w780');
    if (runtime.textureUrl === url) return;
    this.textureLoader.load(url, (texture) => {
      if (
        this.isDisposed ||
        this.selectedIndex === null ||
        this.cases[this.selectedIndex] !== runtime
      ) {
        texture.dispose();
        return;
      }
      this.prepareTexture(texture);
      if (this.inspectPosterTexture) this.inspectPosterTexture.dispose();
      this.inspectPosterTexture = texture;
      runtime.poster.material.map = texture;
      runtime.poster.material.color.set('#ffffff');
      runtime.poster.material.needsUpdate = true;
    });
  }

  private disposeBackdrop() {
    if (this.backdropPlane) {
      this.camera.remove(this.backdropPlane);
      this.backdropPlane.geometry.dispose();
      this.backdropPlane.material.dispose();
      this.backdropPlane = null;
    }
    if (this.backdropTexture) {
      this.backdropTexture.dispose();
      this.backdropTexture = null;
    }
  }

  /**
   * Two-phase flight (technique 6): phase A moves the case straight off its
   * wall along the wall normal — pure normal motion cannot intersect coplanar
   * neighbors — and only then does phase B yaw it toward the camera and glide
   * it to the inspect anchor.
   */
  private applyFlight(runtime: CaseRuntime, progress: number) {
    const t = clamp(progress, 0, 1);
    const clearance = this.smooth(Math.min(1, t / 0.55));
    const presentation = this.smooth(Math.max(0, (t - 0.55) / 0.45));

    const slot = runtime.slot;
    const wallNormalX = slot.side === 'left' ? 1 : -1;
    const clearDistance = 0.55;

    // Inspect anchor in world space, in front of the camera.
    const camZ = this.walkZ();
    const isMobile = this.canvas.clientWidth < 760;
    const anchor = new THREE.Vector3(
      0,
      EYE_Y + (isMobile ? 0.12 : 0.03),
      camZ - INSPECT_DISTANCE,
    );

    const clearedX = slot.x + wallNormalX * clearDistance * clearance;
    const clearedY = slot.y;
    const clearedZ = slot.z;

    runtime.group.position.set(
      THREE.MathUtils.lerp(clearedX, anchor.x, presentation),
      THREE.MathUtils.lerp(clearedY, anchor.y, presentation),
      THREE.MathUtils.lerp(clearedZ, anchor.z, presentation),
    );
    runtime.group.rotation.y = THREE.MathUtils.lerp(
      slot.yawY,
      0,
      presentation,
    );
    const inspectScale = isMobile ? 1.05 : 1.25;
    runtime.group.scale.setScalar(
      THREE.MathUtils.lerp(slot.scale, inspectScale, presentation),
    );
  }

  private restoreSlot(runtime: CaseRuntime) {
    const slot = runtime.slot;
    runtime.group.position.set(slot.x, slot.y, slot.z);
    runtime.group.rotation.y = slot.yawY;
    runtime.group.scale.setScalar(slot.scale);
    runtime.swayGroup.position.set(0, 0, 0);
    runtime.swayGroup.rotation.set(0, 0, 0);
  }

  private smooth(value: number): number {
    const t = clamp(value, 0, 1);
    return t * t * (3 - 2 * t);
  }

  // ── Frame loop ───────────────────────────────────────────────────────────

  private walkZ(): number {
    if (this.layout.walkStops.length === 0) return 0;
    const lower = Math.floor(this.walk);
    const upper = Math.min(this.layout.walkStops.length - 1, Math.ceil(this.walk));
    const fraction = this.walk - lower;
    return THREE.MathUtils.lerp(
      this.layout.walkStops[lower] ?? 0,
      this.layout.walkStops[upper] ?? 0,
      fraction,
    );
  }

  private emitFocus(flatIndex: number) {
    const runtime = this.cases[flatIndex];
    if (!runtime) return;
    const room = this.layout.rooms.find((r) => r.tier === runtime.slot.tier);
    this.callbacks.onFocusChange({
      itemId: runtime.item.id,
      tier: runtime.slot.tier,
      indexInTier: runtime.slot.indexInTier,
      roomIndex: room?.roomIndex ?? 0,
    });
  }

  private announceRoom() {
    const cameraRoom = roomIndexAtZ(this.layout, this.walkZ());
    if (cameraRoom !== this.lastRoomIndex) {
      this.lastRoomIndex = cameraRoom;
      const room = this.layout.rooms[cameraRoom];
      if (room) {
        const label = this.tierLabels[room.tier] ?? room.tier;
        this.callbacks.onStatus(
          `${room.tier} Tier room — ${label} — ${room.slots.length} ${
            room.slots.length === 1 ? 'work' : 'works'
          } on display`,
        );
        // Bounce light travels to the current room (one light, never per case).
        this.bounceLight.position.set(
          0,
          1.2,
          (room.startZ + room.endZ) / 2,
        );
      }
    }
  }

  private animate = () => {
    if (this.isDisposed) return;
    this.animationFrame = requestAnimationFrame(this.animate);
    const timestamp = performance.now();
    const elapsed = timestamp / 1000;
    const delta = clamp(
      (timestamp - this.lastTimestamp) / 1000 || 1 / 60,
      0,
      MAX_DELTA,
    );
    this.lastTimestamp = timestamp;

    this.updateState(delta, timestamp, elapsed);
    this.renderer.render(this.scene, this.camera);
  };

  private updateState(delta: number, timestamp: number, elapsed: number) {
    const lambdaBoost = this.reducedMotion ? 2.2 : 1;

    if (this.mode === 'hall') {
      if (!this.pointerDown && timestamp - this.lastInputTime > SNAP_IDLE_MS) {
        this.targetWalk = damp(
          this.targetWalk,
          Math.round(this.targetWalk),
          8.5 * lambdaBoost,
          delta,
        );
      }
      this.walk = damp(this.walk, this.targetWalk, 10 * lambdaBoost, delta);

      const nextFocus = clamp(
        Math.round(this.walk),
        0,
        Math.max(0, this.cases.length - 1),
      );
      if (nextFocus !== this.focusIndex) {
        this.focusIndex = nextFocus;
        this.emitFocus(nextFocus);
      }
      this.announceRoom();
      this.updateTextureWindow();

      this.dimQuad.visible = false;
      (this.dimQuad.material as THREE.MeshBasicMaterial).opacity = damp(
        (this.dimQuad.material as THREE.MeshBasicMaterial).opacity,
        0,
        10,
        delta,
      );
    } else if (this.mode === 'focusing') {
      const duration = this.reducedMotion
        ? REDUCED_FOCUS_DURATION
        : FOCUS_IN_DURATION;
      this.focusProgress = clamp(this.focusProgress + delta / duration, 0, 1);
      if (this.focusProgress >= 1) {
        this.mode = 'inspect';
        this.callbacks.onModeChange(
          'inspect',
          this.selectedIndex !== null
            ? this.cases[this.selectedIndex].item.id
            : null,
        );
        if (this.selectedIndex !== null) {
          this.callbacks.onStatus(
            `Inspecting ${this.cases[this.selectedIndex].item.title}`,
          );
        }
      }
    } else if (this.mode === 'returning') {
      const duration = this.reducedMotion
        ? REDUCED_FOCUS_DURATION
        : FOCUS_OUT_DURATION;
      this.focusProgress = clamp(this.focusProgress - delta / duration, 0, 1);
      if (this.focusProgress <= 0) {
        if (this.selectedIndex !== null) {
          const runtime = this.cases[this.selectedIndex];
          this.restoreSlot(runtime);
          // Drop the pinned w780 poster back to the windowed w342.
          if (this.inspectPosterTexture) {
            this.inspectPosterTexture.dispose();
            this.inspectPosterTexture = null;
            runtime.texture = null;
            runtime.textureUrl = null;
            runtime.poster.material.map = null;
            runtime.poster.material.color.set('#101012');
            runtime.poster.material.needsUpdate = true;
          }
        }
        this.disposeBackdrop();
        this.backdropForItemId = null;
        this.selectedIndex = null;
        this.mode = 'hall';
        this.callbacks.onModeChange('hall', null);
        this.callbacks.onStatus('Returned to the hall');
        this.updateTextureWindow(true);
        this.canvas.focus({ preventScroll: true });
      }
    }

    // Flight + environment for the selected case.
    if (this.selectedIndex !== null && this.mode !== 'hall') {
      const runtime = this.cases[this.selectedIndex];
      const eased =
        this.mode === 'returning'
          ? this.focusProgress
          : this.smooth(this.focusProgress);
      this.applyFlight(runtime, eased);

      this.dimQuad.visible = true;
      const dimMaterial = this.dimQuad.material as THREE.MeshBasicMaterial;
      dimMaterial.opacity = 0.85 * eased;
      if (this.backdropPlane) {
        const material = this.backdropPlane
          .material as THREE.MeshBasicMaterial;
        material.opacity = damp(material.opacity, 0.9 * eased, 4, delta);
      }

      // Multi-frequency idle sway — inspect only, never under reduced motion.
      const swayStrength =
        this.mode === 'inspect' && !this.reducedMotion ? 1 : 0;
      const phase = elapsed * 0.78;
      runtime.swayGroup.position.y =
        Math.sin(phase) * IDLE_LIFT * swayStrength;
      runtime.swayGroup.rotation.set(
        Math.sin(phase * 0.73 + 0.8) * IDLE_PITCH * swayStrength,
        Math.sin(phase * 0.61) * IDLE_YAW * swayStrength,
        Math.sin(phase * 0.89 + 1.7) * IDLE_ROLL * swayStrength,
      );
    }

    // Camera: eye-height walk along the corridor; asymmetric frustum while
    // inspecting so the case centers in the half beside the placard.
    const camZ = this.walkZ();
    this.camera.position.set(0, EYE_Y, camZ + ROOM_TAIL * 0.4);
    this.camera.lookAt(0, EYE_Y + 0.03, camZ - LOOK_AHEAD);
    this.applyViewOffset();
  }

  private applyViewOffset() {
    const width = Math.max(1, this.canvas.clientWidth);
    const height = Math.max(1, this.canvas.clientHeight);
    const progress =
      this.mode === 'returning'
        ? this.focusProgress
        : this.smooth(this.focusProgress);
    const active = this.selectedIndex !== null && progress > 0.001;
    if (!active) {
      this.camera.clearViewOffset();
      return;
    }
    const isMobile = width < 760;
    if (isMobile) {
      const offsetY = height * MOBILE_SHEET_OFFSET * progress;
      this.camera.setViewOffset(width, height, 0, offsetY, width, height);
    } else {
      const placardWidth = Math.min(
        DESKTOP_PLACARD_MAX,
        width * DESKTOP_PLACARD_RATIO,
      );
      this.camera.setViewOffset(
        width,
        height,
        (placardWidth / 2) * progress,
        0,
        width,
        height,
      );
    }
  }

  private handleResize = () => {
    if (this.isDisposed) return;
    const width = Math.max(1, this.canvas.clientWidth);
    const height = Math.max(1, this.canvas.clientHeight);
    const dprCap = width < 760 ? 1.5 : 1.75;
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, dprCap));
    this.renderer.setSize(width, height, false);
    this.camera.aspect = width / height;
    this.camera.fov = fovForWidth(width);
    this.camera.updateProjectionMatrix();
  };

  // ── Diagnostics & teardown ───────────────────────────────────────────────

  getDiagnostics(): GalleryDiagnostics {
    const info = this.renderer.info;
    return {
      mode: this.mode,
      textures: info.memory.textures,
      drawCalls: info.render.calls,
      triangles: info.render.triangles,
      pixelRatio: this.renderer.getPixelRatio(),
    };
  }

  dispose() {
    if (this.isDisposed) return;
    this.isDisposed = true;
    cancelAnimationFrame(this.animationFrame);
    this.resizeObserver?.disconnect();

    this.canvas.removeEventListener('wheel', this.handleWheel);
    this.canvas.removeEventListener('pointerdown', this.handlePointerDown);
    this.canvas.removeEventListener('pointermove', this.handlePointerMove);
    this.canvas.removeEventListener('pointerup', this.handlePointerUp);
    this.canvas.removeEventListener('pointercancel', this.handlePointerCancel);
    this.canvas.removeEventListener('keydown', this.handleKeyDown);
    this.canvas.removeEventListener('webglcontextlost', this.handleContextLost);
    this.canvas.removeEventListener(
      'webglcontextrestored',
      this.handleContextRestored,
    );
    window.removeEventListener('blur', this.handleWindowBlur);

    this.disposeBackdrop();
    if (this.inspectPosterTexture) {
      this.inspectPosterTexture.dispose();
      this.inspectPosterTexture = null;
    }
    this.cases.forEach((c) => this.disposeCaseTexture(c));
    this.scene.traverse((object) => {
      if (!(object instanceof THREE.Mesh || object instanceof THREE.Sprite)) {
        return;
      }
      if (object instanceof THREE.Mesh) object.geometry.dispose();
      const materials = Array.isArray(object.material)
        ? object.material
        : [object.material];
      materials.forEach((material) => {
        const withMap = material as THREE.Material & {
          map?: THREE.Texture | null;
        };
        withMap.map?.dispose();
        material?.dispose();
      });
    });
    this.glowTexture.dispose();
    this.renderer.dispose();
    if (import.meta.env.DEV) {
      delete (window as unknown as Record<string, unknown>).__SPOOL_GALLERY__;
    }
  }
}
