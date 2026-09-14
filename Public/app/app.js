// Povar Mini App — vanilla JS + Telegram WebApp
(() => {
  // Telegram SDK грузится асинхронно (см. index.html), поэтому ждём его
  // в init() до 3 секунд. Здесь — только лёгкая инициализация без зависимостей.
  let tg = window.Telegram?.WebApp;
  let initData = new URLSearchParams(window.location.search).get('initData') || '';

  function applyTheme() {
    // Дизайн всегда тёмный — как на animals.serjey.com (тема «Аврора»)
    document.documentElement.setAttribute('data-theme', 'dark');
  }
  applyTheme();

  // --- Config ---
  const API = '/api/v1';
  const state = {
    profile: null,
    tab: 'browse',
    browse: { page: 0, hasNext: false, dishes: [], filter: { keyword: '', category: null, maxPrice: null, sort: 'distance', todayOnly: false, photoOnly: false, city: null } },
    orders: [],
    favorites: [],
    cart: [],
    cartTotal: 0,
  };

  // --- Helpers ---
  function headers() {
    const h = { 'Content-Type': 'application/json' };
    if (initData) h['X-Telegram-Init-Data'] = initData;
    return h;
  }

  async function api(path, opts = {}) {
    const res = await fetch(API + path, {
      credentials: 'include',
      ...opts,
      headers: { ...headers(), ...(opts.headers || {}) },
    });
    if (!res.ok) {
      let msg = res.statusText;
      try { const j = await res.json(); msg = j.reason || j.error || msg; } catch {}
      const err = new Error(msg || `HTTP ${res.status}`);
      err.status = res.status;
      throw err;
    }
    const ct = res.headers.get('content-type') || '';
    if (res.status === 204 || res.headers.get('content-length') === '0') return null;
    if (ct.includes('application/json')) return res.json();
    return res.text();
  }

  function isAuthError(e) {
    return e && (e.status === 401 || (typeof e.message === 'string' && e.message.includes('401')));
  }

  function isWebsite() {
    return document.documentElement.classList.contains('is-website');
  }

  // CTA входа: лендинга больше нет — ведём в бота (Mini App с авторизацией)
  function loginLinkHtml() {
    return '<a href="https://t.me/uncle_masha_bot" target="_blank" class="btn btn-primary">Открыть в Telegram</a>';
  }

  function toast(msg, type = 'success') {
    const c = document.getElementById('toastContainer');
    const el = document.createElement('div');
    el.className = `toast ${type}`;
    const icon = type === 'success' ? '✅' : type === 'error' ? '❌' : '⚠️';
    el.innerHTML = `<span style="font-size:18px">${icon}</span><span class="toast-message">${escapeHtml(msg)}</span><button class="toast-close">×</button>`;
    el.querySelector('.toast-close').onclick = () => el.remove();
    c.appendChild(el);
    setTimeout(() => el.remove(), 4000);
  }

  function escapeHtml(s) {
    if (!s) return '';
    return String(s).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  }

  function categoryEmoji(cat) {
    const m = { breakfast: '🥞', lunch: '🍲', dinner: '🍽', dessert: '🍰', drink: '🥤' };
    return m[cat] || '🍲';
  }

  function categoryLabel(cat) {
    const m = { breakfast: 'Завтрак', lunch: 'Обед', dinner: 'Ужин', dessert: 'Десерт', drink: 'Напиток' };
    return m[cat] || cat;
  }

  // --- КБЖУ ---
  // На карточке показываем одну цифру: калории на порцию, если известен вес
  // порции, иначе на 100 г.
  function nutritionChip(d) {
    const n = d.nutrition;
    if (!n) return '';
    const perPortion = n.kcalPerPortion != null;
    const kcal = perPortion ? n.kcalPerPortion : n.kcalPer100g;
    if (kcal == null) return '';
    const suffix = perPortion ? '' : '/100 г';
    return `<span class="pill pill-kcal" title="Калорийность">🔥 ${Math.round(kcal)} ккал${suffix}</span>`;
  }

  // Полный блок БЖУ для карточки блюда в модалке.
  function nutritionBlock(d) {
    const n = d.nutrition;
    if (!n) return '';
    const perPortion = n.kcalPerPortion != null;
    const pick = (portion, per100) => (perPortion ? portion : per100);
    const rows = [
      ['Калории', pick(n.kcalPerPortion, n.kcalPer100g), 'ккал'],
      ['Белки', pick(n.proteinPerPortion, n.proteinPer100g), 'г'],
      ['Жиры', pick(n.fatPerPortion, n.fatPer100g), 'г'],
      ['Углеводы', pick(n.carbsPerPortion, n.carbsPer100g), 'г'],
    ].filter(r => r[1] != null);
    if (!rows.length) return '';

    const basis = perPortion
      ? `на порцию${n.portionWeightG ? ` (${n.portionWeightG} г)` : ''}`
      : 'на 100 г';
    return `
      <div class="nutrition-block">
        <div class="nutrition-head">🍏 КБЖУ <span>${basis}</span></div>
        <div class="nutrition-grid">
          ${rows.map(r => `<div class="nutrition-cell"><b>${formatNumber(r[1])}</b><span>${r[2]}</span><i>${r[0]}</i></div>`).join('')}
        </div>
      </div>`;
  }

  function formatNumber(v) {
    if (v == null) return '—';
    return Number.isInteger(v) ? String(v) : String(Math.round(v * 10) / 10);
  }

  // Автозаполнение КБЖУ из открытой базы продуктов Open Food Facts.
  function initNutritionSearch() {
    const input = document.getElementById('nutriQuery');
    const box = document.getElementById('nutriResults');
    if (!input || !box) return;

    let timer = null;
    let lastQuery = '';

    const closeBox = () => { box.style.display = 'none'; };

    input.addEventListener('blur', () => setTimeout(closeBox, 220));
    input.addEventListener('input', () => {
      clearTimeout(timer);
      const q = input.value.trim();
      if (q.length < 3) { closeBox(); box.innerHTML = ''; return; }
      timer = setTimeout(async () => {
        if (q === lastQuery) return;
        lastQuery = q;
        box.style.display = 'block';
        box.innerHTML = '<div class="nutri-hint">Ищем…</div>';
        try {
          const items = await api('/nutrition/search?q=' + encodeURIComponent(q));
          if (!items.length) {
            box.innerHTML = '<div class="nutri-hint">Ничего не нашлось — впишите цифры вручную</div>';
            return;
          }
          box.innerHTML = items.map((p, i) => {
            const vals = [
              p.kcalPer100g != null ? `${formatNumber(p.kcalPer100g)} ккал` : null,
              p.proteinPer100g != null ? `Б ${formatNumber(p.proteinPer100g)}` : null,
              p.fatPer100g != null ? `Ж ${formatNumber(p.fatPer100g)}` : null,
              p.carbsPer100g != null ? `У ${formatNumber(p.carbsPer100g)}` : null,
            ].filter(Boolean).join(' • ');
            return `<button type="button" class="nutri-item" data-i="${i}">
              <span class="nutri-name">${escapeHtml(p.name)}${p.brand ? ` <i>${escapeHtml(p.brand)}</i>` : ''}</span>
              <span class="nutri-vals">${vals} <em>на 100 г</em></span>
            </button>`;
          }).join('');
          box.querySelectorAll('.nutri-item').forEach(btn => {
            btn.addEventListener('click', () => {
              const p = items[parseInt(btn.dataset.i, 10)];
              const set = (id, v) => { const el = document.getElementById(id); if (el) el.value = v == null ? '' : v; };
              set('dishKcal', p.kcalPer100g);
              set('dishProtein', p.proteinPer100g);
              set('dishFat', p.fatPer100g);
              set('dishCarbs', p.carbsPer100g);
              input.value = p.name;
              closeBox();
              toast(`КБЖУ подставлено: ${p.name}`);
            });
          });
        } catch (e) {
          box.innerHTML = '<div class="nutri-hint">Не удалось получить данные — впишите вручную</div>';
        }
      }, 450);
    });
  }

  // Подсказки адреса через Nominatim (запрос идёт через наш сервер).
  // Возвращает объект, в который складываются координаты выбранного адреса.
  function initAddressSearch() {
    const picked = { lat: null, lon: null, label: null };
    const input = document.getElementById('orderAddress');
    const box = document.getElementById('addrResults');
    if (!input || !box) return picked;

    let timer = null;
    let lastQuery = '';
    const closeBox = () => { box.style.display = 'none'; };

    input.addEventListener('input', () => {
      // Адрес поправили руками — прежние координаты больше не подходят.
      picked.lat = null; picked.lon = null; picked.label = null;
      clearTimeout(timer);
      const q = input.value.trim();
      if (q.length < 4) { closeBox(); box.innerHTML = ''; return; }
      timer = setTimeout(async () => {
        if (q === lastQuery) return;
        lastQuery = q;
        box.style.display = 'block';
        box.innerHTML = '<div class="nutri-hint">Ищем адрес…</div>';
        try {
          const items = await api('/geo/search?q=' + encodeURIComponent(q));
          if (!items.length) {
            box.innerHTML = '<div class="nutri-hint">Ничего не нашли — введите адрес вручную</div>';
            return;
          }
          box.innerHTML = items
            .map((p, i) => `<button type="button" class="addr-item" data-i="${i}">📍 ${escapeHtml(p.label)}</button>`)
            .join('');
          box.querySelectorAll('.addr-item').forEach(btn => {
            btn.addEventListener('click', () => {
              const p = items[parseInt(btn.dataset.i, 10)];
              picked.lat = p.lat; picked.lon = p.lon; picked.label = p.label;
              input.value = p.label;
              closeBox();
              toast('Адрес выбран');
            });
          });
        } catch (e) {
          box.innerHTML = '<div class="nutri-hint">Подсказки недоступны — введите адрес вручную</div>';
        }
      }, 600);
    });

    input.addEventListener('blur', () => setTimeout(closeBox, 250));
    return picked;
  }

  /// Собирает КБЖУ из формы блюда.
  function readNutritionForm() {
    const num = (id) => {
      const v = parseFloat(document.getElementById(id)?.value);
      return Number.isFinite(v) ? v : null;
    };
    const weight = parseInt(document.getElementById('dishPortionWeight')?.value, 10);
    return {
      caloriesPer100g: num('dishKcal'),
      proteinPer100g: num('dishProtein'),
      fatPer100g: num('dishFat'),
      carbsPer100g: num('dishCarbs'),
      portionWeightG: Number.isFinite(weight) ? weight : null,
    };
  }

  function statusTitle(status) {
    const m = { new: 'Новый', accepted: 'Принят', cooking: 'Готовится', ready: 'Готов', onTheWay: 'В пути', delivered: 'Доставлен', cancelled: 'Отменён' };
    return m[status] || status;
  }

  function statusClass(status) {
    const m = { new: 'new', accepted: 'new', cooking: 'cooking', ready: 'ready', onTheWay: 'cooking', delivered: 'delivered', cancelled: 'cancelled' };
    return m[status] || 'new';
  }

  function formatPrice(price) {
    return Math.round(price).toLocaleString('ru-RU');
  }

  function haptic(type) {
    try {
      if (tg?.HapticFeedback) {
        if (type === 'success' || type === 'error') tg.HapticFeedback.notificationOccurred(type);
        else tg.HapticFeedback.selectionChanged();
      }
    } catch {}
  }

  // Читает фото, уменьшает до maxSize и возвращает data URL (JPEG)
  function readAndResizePhoto(file, maxSize = 1280) {
    return new Promise((resolve, reject) => {
      if (!file) { resolve(null); return; }
      if (file.size > 8 * 1024 * 1024) { reject(new Error('Фото слишком большое (максимум 8 МБ)')); return; }
      const reader = new FileReader();
      reader.onerror = () => reject(new Error('Не удалось прочитать фото'));
      reader.onload = () => {
        const img = new Image();
        img.onerror = () => reject(new Error('Не удалось обработать фото'));
        img.onload = () => {
          const scale = Math.min(1, maxSize / Math.max(img.width, img.height));
          if (scale >= 1) { resolve(reader.result); return; }
          const canvas = document.createElement('canvas');
          canvas.width = Math.round(img.width * scale);
          canvas.height = Math.round(img.height * scale);
          const ctx = canvas.getContext('2d');
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          resolve(canvas.toDataURL('image/jpeg', 0.85));
        };
        img.src = reader.result;
      };
      reader.readAsDataURL(file);
    });
  }

  // --- Modal ---
  const overlay = document.getElementById('modalOverlay');
  const modalTitle = document.getElementById('modalTitle');
  const modalBody = document.getElementById('modalBody');
  const modalFooter = document.getElementById('modalFooter');
  const modalClose = document.getElementById('modalClose');

  function openModal(title, bodyHtml, footerHtml) {
    modalTitle.textContent = title;
    modalBody.innerHTML = bodyHtml;
    modalFooter.innerHTML = footerHtml || '';
    overlay.style.display = 'flex';
    document.body.style.overflow = 'hidden';
  }

  function closeModal() {
    overlay.style.display = 'none';
    document.body.style.overflow = '';
  }

  overlay.addEventListener('click', (e) => { if (e.target === overlay) closeModal(); });
  modalClose.addEventListener('click', closeModal);

  // --- Tabs ---
  const tabs = ['browse', 'orders', 'favorites', 'cart', 'profile'];
  function switchTab(name) {
    state.tab = name;
    tabs.forEach(t => {
      const el = document.getElementById('tab' + t.charAt(0).toUpperCase() + t.slice(1));
      if (el) el.style.display = t === name ? 'block' : 'none';
      document.querySelector(`[data-tab="${t}"]`)?.classList.toggle('active', t === name);
    });
    const fab = document.getElementById('fab');
    fab.classList.toggle('hidden', !(name === 'browse' && isCook()));

    if (name === 'browse' && state.browse.dishes.length === 0) loadBrowse(true);
    if (name === 'orders') loadOrders();
    if (name === 'favorites' && state.favorites.length === 0) loadFavorites();
    if (name === 'cart') loadCart();
    if (name === 'profile') loadProfile();
  }

  function isCook() { return state.profile && state.profile.role === 'cook'; }
  function hasRole() { return state.profile && (state.profile.role === 'cook' || state.profile.role === 'client'); }

  document.querySelectorAll('.nav-item').forEach(btn => {
    btn.addEventListener('click', () => switchTab(btn.dataset.tab));
  });

  document.getElementById('profileBtn').addEventListener('click', () => switchTab('profile'));
  document.getElementById('fab').addEventListener('click', () => openAddDish());
  document.getElementById('goToBrowse')?.addEventListener('click', () => switchTab('browse'));
  document.getElementById('goToBrowseFromCart')?.addEventListener('click', () => switchTab('browse'));
  document.getElementById('resetFromEmpty')?.addEventListener('click', resetFilters);

  // --- Browse ---
  const listingsContainer = document.getElementById('listingsContainer');
  const loadMoreBtn = document.getElementById('loadMoreBtn');
  const emptyListings = document.getElementById('emptyListings');

  function currentBrowseQuery(page) {
    const f = state.browse.filter;
    const q = new URLSearchParams();
    if (f.keyword) q.set('q', f.keyword);
    if (f.category) q.set('category', f.category);
    if (f.maxPrice) q.set('maxPrice', String(f.maxPrice));
    if (f.city) q.set('city', f.city);
    q.set('sort', f.sort || 'distance');
    q.set('todayOnly', String(!!f.todayOnly));
    q.set('photoOnly', String(!!f.photoOnly));
    q.set('page', String(page));
    return '?' + q.toString();
  }

  async function loadBrowse(reset = false) {
    const page = reset ? 0 : state.browse.page;
    if (reset) {
      listingsContainer.innerHTML = '<div class="loading"><div class="spinner"></div><p>Загружаем блюда...</p></div>';
      emptyListings.style.display = 'none';
      loadMoreBtn.style.display = 'none';
    }
    try {
      const data = await api('/browse' + currentBrowseQuery(page));
      if (reset) {
        state.browse.dishes = data.dishes;
        state.browse.page = data.page;
        state.browse.hasNext = data.hasNext;
      } else {
        state.browse.dishes.push(...data.dishes);
        state.browse.page = data.page;
        state.browse.hasNext = data.hasNext;
      }
      renderBrowse();
    } catch (e) {
      listingsContainer.innerHTML = `<div class="empty-state"><p style="color:var(--text-500)">Ошибка: ${escapeHtml(e.message)}</p><button class="btn btn-secondary" onclick="location.reload()">Попробовать снова</button></div>`;
      if (!initData) {
        listingsContainer.innerHTML += `<p style="text-align:center;color:var(--text-400);margin-top:12px;font-size:13px">Откройте Mini App из Telegram, чтобы увидеть данные.</p>`;
      }
    }
  }

  function renderBrowse() {
    const titleEl = document.getElementById('browseTitle');
    const countEl = document.getElementById('browseCount');
    const displayList = state.browse.dishes;

    if (titleEl) {
      const f = state.browse.filter;
      let t = (state.profile && state.profile.hasLocation) ? 'Меню поблизости' : 'Каталог блюд';
      if (f.category) t = categoryLabel(f.category);
      if (f.keyword) t += ` • «${f.keyword}»`;
      if (f.todayOnly) t += ' • Сегодня';
      titleEl.textContent = t;
    }

    if (countEl) {
      const n = displayList.length;
      countEl.textContent = n ? `Найдено ${n}${state.browse.hasNext ? '+' : ''} • стр. ${state.browse.page + 1}` : 'Загружаем...';
      if (displayList.length === 0 && !listingsContainer.querySelector('.loading')) countEl.textContent = 'Блюд не нашлось';
    }

    if (displayList.length === 0) {
      listingsContainer.innerHTML = '';
      emptyListings.style.display = 'flex';
      loadMoreBtn.style.display = 'none';
      return;
    }

    emptyListings.style.display = 'none';
    listingsContainer.innerHTML = displayList.map(d => dishCardHtml(d)).join('');
    bindDishCards(listingsContainer);
    loadMoreBtn.style.display = state.browse.hasNext ? 'block' : 'none';
    loadMoreBtn.textContent = `Показать ещё (стр. ${state.browse.page + 2})`;
  }

  loadMoreBtn.addEventListener('click', () => {
    state.browse.page += 1;
    loadBrowse(false);
  });

  // Category pills
  document.querySelectorAll('.cat-pill').forEach(pill => {
    pill.addEventListener('click', () => {
      document.querySelectorAll('.cat-pill').forEach(p => p.classList.remove('active'));
      pill.classList.add('active');
      const cat = pill.dataset.cat;
      state.browse.filter.category = cat === 'all' ? null : cat;
      loadBrowse(true);
      haptic();
    });
  });

  // Search — ищет по всему каталогу на сервере
  const searchInput = document.getElementById('searchInput');
  const searchBtn = document.getElementById('searchBtn');
  function doSearch() {
    const q = (searchInput?.value || '').trim();
    state.browse.filter.keyword = q;
    loadBrowse(true);
  }
  searchBtn?.addEventListener('click', doSearch);
  searchInput?.addEventListener('keydown', e => { if (e.key === 'Enter') doSearch(); });
  searchInput?.addEventListener('input', () => { if (!searchInput.value.trim() && state.browse.filter.keyword) { state.browse.filter.keyword = ''; loadBrowse(true); } });

  // Sidebar filters
  document.getElementById('applyFilters')?.addEventListener('click', () => {
    state.browse.filter.category = document.getElementById('sidebarCategory')?.value || null;
    state.browse.filter.maxPrice = document.getElementById('sidebarPrice')?.value || null;
    state.browse.filter.sort = document.getElementById('sidebarSort')?.value || 'distance';
    state.browse.filter.todayOnly = document.getElementById('fToday')?.checked || false;
    state.browse.filter.photoOnly = document.getElementById('fPhoto')?.checked || false;
    state.browse.filter.city = document.getElementById('sidebarCity')?.value || null;
    state.browse.filter.keyword = searchInput?.value?.trim() || '';
    loadBrowse(true);
    toast('Фильтры применены');
  });

  document.getElementById('resetFilters')?.addEventListener('click', resetFilters);

  function resetFilters() {
    document.getElementById('sidebarCategory').value = '';
    document.getElementById('sidebarPrice').value = '';
    document.getElementById('sidebarSort').value = 'distance';
    document.getElementById('sidebarCity').value = '';
    document.getElementById('fToday').checked = false;
    document.getElementById('fPhoto').checked = false;
    if (searchInput) searchInput.value = '';
    document.querySelectorAll('.cat-pill').forEach(p => p.classList.remove('active'));
    document.querySelector('.cat-pill[data-cat="all"]')?.classList.add('active');
    state.browse.filter = { keyword: '', category: null, maxPrice: null, sort: 'distance', todayOnly: false, photoOnly: false, city: null };
    loadBrowse(true);
    toast('Фильтры сброшены');
  }

  document.getElementById('sortSelect')?.addEventListener('change', e => {
    state.browse.filter.sort = e.target.value;
    loadBrowse(true);
  });

  document.getElementById('createTopBtn')?.addEventListener('click', openAddDish);
  document.getElementById('logoBtn')?.addEventListener('click', () => switchTab('browse'));

  function dishCardHtml(d) {
    const emoji = categoryEmoji(d.category);
    const photoUrl = d.photoUrl;
    const isPhotoUrl = photoUrl && (photoUrl.startsWith('/uploads/') || photoUrl.startsWith('/api/v1/uploads/') || photoUrl.startsWith('http'));
    const imageContent = isPhotoUrl ? `<img src="${escapeHtml(photoUrl)}" loading="lazy" style="width:100%;height:100%;object-fit:cover">` : `<span class="img-emoji">${emoji}</span>`;
    const todayPill = d.isToday ? '<span class="pill pill-today">🔥 Сегодня</span>' : '';
    const portionsPill = d.isToday && d.portionsLeft != null ? `<span class="pill">🍽 Осталось ${d.portionsLeft}</span>` : '';
    const photoPill = isPhotoUrl ? '<span class="pill pill-photo">📷</span>' : '';
    const kcalPill = nutritionChip(d);
    const ratingHtml = d.cook?.rating ? `<span class="listing-rating">⭐ ${d.cook.rating.toFixed(1)}</span>` : '';
    const distanceHtml = d.cook?.distance != null ? `<span class="listing-distance">📍 ${d.cook.distance.toFixed(1)} км</span>` : '';
    const isInCart = state.cart.some(c => (c.dish?.id || c.dishId) === d.id);

    return `<article class="listing-card" data-id="${d.id}" data-category="${d.category || ''}">
      <div class="listing-image">${imageContent}<div class="badge-row"><div class="badge-left">${todayPill}${portionsPill}</div><div class="badge-right">${kcalPill}${photoPill}</div></div></div>
      <div class="listing-content">
        <div class="listing-header">
          <div class="listing-type"><span class="type-dot"></span>${categoryLabel(d.category)}</div>
          <div class="listing-meta">${ratingHtml}${distanceHtml}</div>
        </div>
        <h3 class="listing-title">${escapeHtml(d.title)}</h3>
        <p class="listing-cook" style="cursor:pointer" data-cook="${escapeHtml(d.cook?.id || '')}">${escapeHtml(d.cook?.name || 'Повар')}</p>
        ${d.details ? `<p class="listing-desc">${escapeHtml(d.details)}</p>` : ''}
        <div class="listing-footer">
          <div class="listing-price${d.isToday ? ' hot' : ''}">💰 ${formatPrice(d.price)}₽</div>
          <div class="listing-actions">
            <button class="favorite-btn${d.isFavorite ? ' active' : ''}" data-fav="${d.id}" aria-label="В избранное">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="${d.isFavorite ? 'white' : 'none'}" stroke="currentColor" stroke-width="2"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"></path></svg>
            </button>
            <button class="cart-btn${isInCart ? ' in-cart' : ''}" data-add-cart="${d.id}">${isInCart ? '✓ В корзине' : 'В корзину'}</button>
          </div>
        </div>
      </div>
    </article>`;
  }

  function bindDishCards(container) {
    container.querySelectorAll('[data-fav]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        if (!initData) { toast('Войдите через Telegram', 'warning'); return; }
        const id = btn.dataset.fav;
        btn.disabled = true;
        try {
          await api(`/favorites/${id}`, { method: 'POST' });
          btn.classList.toggle('active');
          const svg = btn.querySelector('svg');
          if (btn.classList.contains('active')) {
            svg.setAttribute('fill', 'white');
            toast('Добавлено в избранное');
          } else {
            svg.setAttribute('fill', 'none');
            toast('Удалено из избранного');
          }
          haptic('success');
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    });

    container.querySelectorAll('[data-add-cart]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        if (!initData) { toast('Войдите через Telegram', 'warning'); return; }
        const id = btn.dataset.addCart;
        btn.disabled = true;
        try {
          await api('/cart', { method: 'POST', body: JSON.stringify({ dishId: id, quantity: 1 }) });
          btn.classList.add('in-cart');
          btn.textContent = '✓ В корзине';
          haptic('success');
          toast('Добавлено в корзину');
          loadCart();
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    });

    container.querySelectorAll('.listing-cook[data-cook]').forEach(el => {
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        const id = el.dataset.cook;
        if (id) openCookProfile(id);
      });
    });

    container.querySelectorAll('.listing-card').forEach(card => {
      // свечение карточки, следующее за курсором
      card.addEventListener('pointermove', (e) => {
        const r = card.getBoundingClientRect();
        card.style.setProperty('--mx', (e.clientX - r.left) + 'px');
        card.style.setProperty('--my', (e.clientY - r.top) + 'px');
      });
      card.addEventListener('click', () => { const id = card.dataset.id; if (id) openDishDetail(id); });
    });
  }

  // --- Dish Detail ---
  async function openDishDetail(id) {
    let dish = state.browse.dishes.find(d => d.id === id);
    if (!dish) {
      try { dish = await api(`/dishes/${id}`); } catch { toast('Не удалось загрузить блюдо', 'error'); return; }
    }
    if (!dish) return;

    const emoji = categoryEmoji(dish.category);
    const photoUrl = dish.photoUrl;
    const isPhotoUrl = photoUrl && (photoUrl.startsWith('/uploads/') || photoUrl.startsWith('/api/v1/uploads/') || photoUrl.startsWith('http'));
    const imageHtml = isPhotoUrl ? `<img src="${escapeHtml(photoUrl)}" style="width:100%;height:200px;object-fit:cover;border-radius:12px">` : `<div style="font-size:80px;text-align:center;padding:20px;background:var(--surface-3);border-radius:16px">${emoji}</div>`;

    const soldOut = dish.isToday && dish.portionsLeft === 0;
    openModal(escapeHtml(dish.title), `
      <div style="display:flex;flex-direction:column;gap:12px">
        ${imageHtml}
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <span style="background:var(--surface-3);padding:6px 10px;border-radius:8px;font-size:13px">${categoryLabel(dish.category)}</span>
          <span style="background:var(--surface-3);padding:6px 10px;border-radius:8px;font-size:13px">💰 ${formatPrice(dish.price)}₽</span>
          ${dish.isToday ? '<span style="background:#FF6B35;color:white;padding:6px 10px;border-radius:8px;font-size:13px">🔥 Сегодня</span>' : ''}
          ${soldOut ? '<span style="background:#FF3B30;color:white;padding:6px 10px;border-radius:8px;font-size:13px">Раскуплено</span>' : ''}
        </div>
        ${dish.details ? `<p>${escapeHtml(dish.details)}</p>` : ''}
        ${nutritionBlock(dish)}
        <p style="color:var(--text-500);font-size:13px">👨‍🍳 Повар: ${escapeHtml(dish.cook?.name || 'Неизвестный')}</p>
        ${dish.cook?.rating ? `<p style="color:var(--text-500);font-size:13px">⭐ Рейтинг: ${dish.cook.rating.toFixed(1)}</p>` : ''}
        ${dish.cook?.distance != null ? `<p style="color:var(--text-500);font-size:13px">📍 ${dish.cook.distance.toFixed(1)} км от вас</p>` : ''}
        ${dish.isToday && dish.portionsLeft != null ? `<p style="color:var(--text-500);font-size:13px">🍽 Осталось порций: ${dish.portionsLeft}</p>` : ''}
        ${dish.cook?.id ? `<p style="color:var(--brand);font-size:13px;cursor:pointer" id="detailCookLink">👨‍🍳 Профиль повара →</p>` : ''}
      </div>
    `, `
      <button class="btn btn-secondary" id="detailClose">Закрыть</button>
      ${soldOut && hasRole() && !isCook()
        ? '<button class="btn btn-primary" id="detailWaitlist">🔔 Уведомить о пополнении</button>'
        : `${dish.cook?.username ? `<a href="https://t.me/${escapeHtml(dish.cook.username)}" target="_blank" class="btn btn-secondary">💬 Написать повару</a>` : ''}<button class="btn btn-primary" id="detailAddCart">В корзину</button>`}
    `);

    document.getElementById('detailClose')?.addEventListener('click', closeModal);
    document.getElementById('detailCookLink')?.addEventListener('click', () => { closeModal(); openCookProfile(dish.cook.id); });

    document.getElementById('detailWaitlist')?.addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      try {
        await api(`/dishes/${dish.id}/waitlist`, { method: 'POST' });
        toast('Вы в списке ожидания — уведомим, когда порции пополнятся');
        haptic('success');
        btn.textContent = '🔔 Вы в списке ожидания';
      } catch (err) { toast(err.message, 'error'); }
      finally { btn.disabled = false; }
    });

    const addBtn = document.getElementById('detailAddCart');
    if (addBtn) {
      addBtn.addEventListener('click', async () => {
        addBtn.disabled = true;
        try {
          await api('/cart', { method: 'POST', body: JSON.stringify({ dishId: dish.id, quantity: 1 }) });
          closeModal();
          toast('Добавлено в корзину');
          haptic('success');
          loadCart();
          renderBrowse();
        } catch (err) {
          toast(err.message, 'error');
        } finally { addBtn.disabled = false; }
      });
    }
  }

  // --- Cook Profile ---
  async function openCookProfile(cookId) {
    try {
      const cook = await api(`/cook/${cookId}`);
      if (!cook) return;

      const photoHtml = cook.profilePhotoUrl
        ? `<img src="${escapeHtml(cook.profilePhotoUrl)}" style="width:80px;height:80px;border-radius:50%;object-fit:cover">`
        : `<div style="width:80px;height:80px;border-radius:50%;background:var(--brand);color:white;display:flex;align-items:center;justify-content:center;font-size:32px;font-weight:800">${(cook.name || '?')[0]}</div>`;

      const bodyHtml = `
        <div style="display:flex;flex-direction:column;gap:12px;align-items:center;text-align:center">
          ${photoHtml}
          <h2 style="margin:0">${escapeHtml(cook.name)}</h2>
          ${cook.username ? `<a href="https://t.me/${escapeHtml(cook.username)}" target="_blank" style="color:var(--brand);font-size:13px">@${escapeHtml(cook.username)}</a>` : ''}
          ${cook.city ? `<span style="background:var(--surface-3);padding:4px 10px;border-radius:999px;font-size:12px">📍 ${escapeHtml(cook.city)}</span>` : ''}
          ${cook.specialization ? `<span style="background:var(--surface-3);padding:4px 10px;border-radius:999px;font-size:12px">👨‍🍳 ${escapeHtml(cook.specialization)}</span>` : ''}
          ${cook.bio ? `<p style="color:var(--text-500);font-size:14px;line-height:1.5">${escapeHtml(cook.bio)}</p>` : ''}
        </div>
        <div style="display:flex;gap:16px;justify-content:center;flex-wrap:wrap">
          ${cook.rating ? `<span style="font-size:13px">⭐ ${cook.rating.toFixed(1)}</span>` : ''}
          ${cook.reviewCount ? `<span style="font-size:13px">📝 ${cook.reviewCount} отзывов</span>` : ''}
          <span style="font-size:13px">🍽 ${cook.dishesCount} блюд</span>
        </div>
        ${cook.pickupSchedule ? `<p style="font-size:13px;color:var(--text-500)">🕐 Выдача: ${escapeHtml(cook.pickupSchedule)}</p>` : ''}
        ${cook.cookingDays ? `<p style="font-size:13px;color:var(--text-500)">📅 Дни готовки: ${escapeHtml(cook.cookingDays)}</p>` : ''}
        ${cook.isAcceptingOrders === false ? `<p style="font-size:13px;color:#FF3B30">⛔ Повар сейчас не принимает заказы</p>` : ''}
      `;

      let footerHtml = `<button class="btn btn-secondary" id="cookClose">Закрыть</button>`;
      if (hasRole() && !isCook()) {
        footerHtml += `<button class="btn btn-primary" id="cookFollow">🔔 Следить за новинками</button>`;
      }
      if (cook.username) {
        footerHtml += `<a href="https://t.me/${escapeHtml(cook.username)}" target="_blank" class="btn btn-primary">💬 Написать повару</a>`;
      }

      openModal(`👨‍🍳 Повар`, bodyHtml, footerHtml);
      document.getElementById('cookClose')?.addEventListener('click', closeModal);
      document.getElementById('cookFollow')?.addEventListener('click', async (e) => {
        const btn = e.currentTarget;
        btn.disabled = true;
        try {
          await api(`/cook/${cookId}/subscribe`, { method: 'POST' });
          toast('Вы подписались на новинки повара');
          haptic('success');
          btn.textContent = '🔔 Вы подписаны';
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    } catch (err) { toast(err.message, 'error'); }
  }

  // --- Orders ---
  const ordersContainer = document.getElementById('ordersContainer');
  const emptyOrders = document.getElementById('emptyOrders');

  async function loadOrders() {
    ordersContainer.innerHTML = '<div class="loading"><div class="spinner"></div><p>Загружаем...</p></div>';
    emptyOrders.style.display = 'none';
    try {
      state.orders = isCook() ? await api('/cook-orders') : await api('/orders') || [];
      renderOrders();
    } catch (e) {
      if (isAuthError(e)) {
        ordersContainer.innerHTML = '';
        emptyOrders.style.display = 'flex';
        emptyOrders.innerHTML = `<div class="empty-illust">🔒</div><h3>Войдите через Telegram</h3><p>Откройте Mini App из бота или авторизуйтесь на сайте</p>${loginLinkHtml()}`;
      } else {
        ordersContainer.innerHTML = `<p style="color:var(--text-500);text-align:center;padding:20px">Ошибка: ${escapeHtml(e.message)}</p>`;
      }
    }
  }

  function renderOrders() {
    if (state.orders.length === 0) {
      ordersContainer.innerHTML = '';
      emptyOrders.style.display = 'flex';
      return;
    }
    emptyOrders.style.display = 'none';
    ordersContainer.innerHTML = isCook()
      ? state.orders.map(cookOrderCardHtml).join('')
      : state.orders.map(clientOrderCardHtml).join('');
    bindOrderActions(ordersContainer);
  }

  function itemsHtml(items) {
    if (!items || items.length === 0) return '';
    return `<div class="order-details" style="margin-top:8px">${items.map(i => `• ${escapeHtml(i.title)} × ${i.quantity} — ${formatPrice(i.price * i.quantity)}₽`).join('<br>')}</div>`;
  }

  function clientOrderCardHtml(o) {
    const cancelable = ['new', 'accepted', 'onTheWay'].includes(o.status);
    const canRate = o.status === 'delivered' && !o.rating;
    const canRepeat = o.status === 'delivered' && o.items && o.items.length > 0;
    return `
      <div class="order-card" data-order="${o.id}">
        <div class="order-header">
          <span class="order-id">#${(o.id || '').substring(0, 8)}</span>
          <span class="order-status ${statusClass(o.status)}">${statusTitle(o.status)}</span>
        </div>
        <div class="order-dish">${escapeHtml(o.items && o.items.length > 1 ? `Заказ из ${o.items.length} блюд` : (o.dish?.title || 'Блюдо'))}</div>
        ${itemsHtml(o.items)}
        <div class="order-details">
          👨‍🍳 ${escapeHtml(o.cook?.name || 'Повар')} •
          💰 ${formatPrice(o.totalPrice)}₽
          ${o.isDelivery ? ` • 🚚 Доставка${o.address ? ` (${escapeHtml(o.address)})` : ''}` : ' • 🍽 Самовывоз'}
          ${deliveryRouteHtml(o)}
          ${o.createdAt ? `<br>📅 ${new Date(o.createdAt).toLocaleDateString('ru-RU')}` : ''}
        </div>
        <div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap">
          ${cancelable ? `<button class="btn btn-danger small" data-cancel="${o.id}">Отменить заказ</button>` : ''}
          ${canRate ? `<button class="btn btn-primary small" data-rate="${o.id}">⭐ Оценить</button>` : ''}
          ${canRepeat ? `<button class="btn btn-secondary small" data-repeat="${o.id}">🔁 Заказать ещё</button>` : ''}
        </div>
      </div>`;
  }

  function cookOrderCardHtml(o) {
    const statuses = ['accepted', 'cooking', 'ready', 'onTheWay', 'delivered', 'cancelled'];
    const options = statuses.map(s => `<option value="${s}" ${s === o.status ? 'selected' : ''}>${statusTitle(s)}</option>`).join('');
    return `
      <div class="order-card" data-order="${o.id}">
        <div class="order-header">
          <span class="order-id">#${(o.id || '').substring(0, 8)}</span>
          <span class="order-status ${statusClass(o.status)}">${statusTitle(o.status)}</span>
        </div>
        ${itemsHtml(o.items)}
        <div class="order-details" style="margin-top:8px">
          🙋 ${escapeHtml(o.client?.name || 'Клиент')}
          ${o.client?.phone ? ` • 📞 ${escapeHtml(o.client.phone)}` : ''}
          ${o.client?.username ? ` • @${escapeHtml(o.client.username)}` : ''}
          <br>💰 ${formatPrice(o.totalPrice)}₽
          ${o.isDelivery ? ` • 🚚 Доставка${o.address ? ` (${escapeHtml(o.address)})` : ''}` : ' • 🍽 Самовывоз'}
          ${deliveryRouteHtml(o)}
          ${o.comment ? `<br>💬 ${escapeHtml(o.comment)}` : ''}
        </div>
        <div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap;align-items:center">
          <select class="select" style="width:auto;min-width:120px;flex:1" data-status-select="${o.id}">${options}</select>
          <button class="btn btn-primary small" data-status-save="${o.id}">Сохранить</button>
        </div>
      </div>`;
  }

  // Расстояние до адреса доставки + кнопка «Маршрут» (считается по дорогам через OSRM).
  function deliveryRouteHtml(o) {
    if (!o.isDelivery) return '';
    const parts = [];
    if (o.distanceKm != null) parts.push(`<br>📏 ${formatNumber(o.distanceKm)} км от повара по прямой`);
    if (o.deliveryLat != null && o.deliveryLon != null) {
      parts.push(`<button class="route-btn" data-route="${o.id}">🚗 Маршрут по дорогам</button>`);
    }
    return parts.length ? `<div class="route-row">${parts.join(' ')}</div>` : '';
  }

  // Делегированный обработчик кнопки «Маршрут» — считаем по дорогам один раз по клику,
  // чтобы не дёргать OSRM на каждый заказ в списке.
  document.addEventListener('click', async (e) => {
    const btn = e.target?.closest?.('[data-route]');
    if (!btn || btn.disabled) return;
    const orderId = btn.dataset.route;
    const original = btn.textContent;
    btn.disabled = true;
    btn.textContent = 'Считаем…';
    try {
      const r = await api(`/orders/${orderId}/route`);
      btn.textContent = `🚗 ${formatNumber(r.distanceKm)} км • ~${Math.round(r.durationMin)} мин`;
      btn.classList.add('loaded');
    } catch (err) {
      btn.textContent = original;
      toast(err.message || 'Не удалось построить маршрут', 'error');
    } finally {
      btn.disabled = false;
    }
  });

  function bindOrderActions(container) {
    container.querySelectorAll('[data-cancel]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        if (!confirm('Отменить заказ?')) return;
        btn.disabled = true;
        try {
          await api(`/orders/${btn.dataset.cancel}/cancel`, { method: 'POST' });
          toast('Заказ отменён');
          haptic('success');
          loadOrders();
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    });

    container.querySelectorAll('[data-rate]').forEach(btn => {
      btn.addEventListener('click', () => openRateOrder(btn.dataset.rate));
    });

    container.querySelectorAll('[data-repeat]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        const order = state.orders.find(o => o.id === btn.dataset.repeat);
        if (!order || !order.items || order.items.length === 0) return;
        btn.disabled = true;
        try {
          for (const item of order.items) {
            await api('/cart', { method: 'POST', body: JSON.stringify({ dishId: item.dishId, quantity: item.quantity }) });
          }
          toast('Блюда снова в корзине');
          haptic('success');
          loadCart();
          switchTab('cart');
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    });

    container.querySelectorAll('[data-status-save]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        const id = btn.dataset.statusSave;
        const select = container.querySelector(`[data-status-select="${id}"]`);
        const status = select?.value;
        if (!status) return;
        btn.disabled = true;
        try {
          await api(`/orders/${id}/status`, { method: 'POST', body: JSON.stringify({ status }) });
          toast('Статус обновлён, клиент уведомлён');
          haptic('success');
          loadOrders();
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    });
  }

  // Оценка полученного заказа
  function openRateOrder(orderId) {
    let stars = 5;
    openModal('⭐ Оцените заказ', `
      <div style="display:flex;flex-direction:column;gap:14px">
        <div style="display:flex;justify-content:center;gap:8px" id="rateStars">
          ${[1, 2, 3, 4, 5].map(v => `<button class="favorite-btn" data-star="${v}" style="width:48px;height:48px;font-size:22px;${v <= stars ? 'background:#FF3B30;border-color:#FF3B30;color:white' : ''}">${v}</button>`).join('')}
        </div>
        <div class="form-group">
          <label>Отзыв (необязательно)</label>
          <textarea id="rateText" rows="3" placeholder="Поделитесь впечатлением..."></textarea>
        </div>
      </div>
    `, `
      <button class="btn btn-secondary" id="rateCancel">Отмена</button>
      <button class="btn btn-primary" id="rateSend">Отправить</button>
    `);

    document.getElementById('rateStars').querySelectorAll('[data-star]').forEach(btn => {
      btn.addEventListener('click', () => {
        stars = parseInt(btn.dataset.star);
        document.getElementById('rateStars').querySelectorAll('[data-star]').forEach(b => {
          const active = parseInt(b.dataset.star) <= stars;
          b.style.background = active ? '#FF3B30' : '';
          b.style.borderColor = active ? '#FF3B30' : '';
          b.style.color = active ? 'white' : '';
        });
      });
    });
    document.getElementById('rateCancel')?.addEventListener('click', closeModal);
    document.getElementById('rateSend')?.addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      try {
        await api(`/orders/${orderId}/rate`, {
          method: 'POST',
          body: JSON.stringify({ rating: stars, reviewText: document.getElementById('rateText')?.value || null })
        });
        closeModal();
        toast('Спасибо за отзыв! Баллы начислены.');
        haptic('success');
        loadOrders();
        loadProfile();
      } catch (err) { toast(err.message, 'error'); }
      finally { btn.disabled = false; }
    });
  }

  // --- Favorites ---
  const favoritesContainer = document.getElementById('favoritesContainer');
  const emptyFavorites = document.getElementById('emptyFavorites');

  async function loadFavorites() {
    favoritesContainer.innerHTML = '<div class="loading"><div class="spinner"></div><p>Загружаем...</p></div>';
    emptyFavorites.style.display = 'none';
    try {
      state.favorites = await api('/favorites') || [];
      renderFavorites();
    } catch (e) {
      if (isAuthError(e)) {
        favoritesContainer.innerHTML = '';
        emptyFavorites.style.display = 'flex';
        emptyFavorites.innerHTML = `<div class="empty-illust">🔒</div><h3>Войдите через Telegram</h3><p>Откройте Mini App из бота или авторизуйтесь на сайте</p>${loginLinkHtml()}`;
      } else {
        favoritesContainer.innerHTML = `<p style="color:var(--text-500);text-align:center;padding:20px">Ошибка: ${escapeHtml(e.message)}</p>`;
      }
    }
  }

  function renderFavorites() {
    if (state.favorites.length === 0) {
      favoritesContainer.innerHTML = '';
      emptyFavorites.style.display = 'flex';
      return;
    }
    emptyFavorites.style.display = 'none';
    favoritesContainer.innerHTML = state.favorites.map(d => dishCardHtml(d)).join('');
    bindDishCards(favoritesContainer);
  }

  // --- Cart ---
  const cartContainer = document.getElementById('cartContainer');
  const emptyCart = document.getElementById('emptyCart');
  const cartSummary = document.getElementById('cartSummary');
  const cartTotal = document.getElementById('cartTotal');

  async function loadCart() {
    cartContainer.innerHTML = '<div class="loading"><div class="spinner"></div><p>Загружаем...</p></div>';
    emptyCart.style.display = 'none';
    cartSummary.style.display = 'none';
    try {
      state.cart = await api('/cart') || [];
      renderCart();
    } catch (e) {
      if (isAuthError(e)) {
        cartContainer.innerHTML = '';
        emptyCart.style.display = 'flex';
        emptyCart.innerHTML = `<div class="empty-illust">🔒</div><h3>Войдите через Telegram</h3><p>Откройте Mini App из бота или авторизуйтесь на сайте</p>${loginLinkHtml()}`;
      } else {
        cartContainer.innerHTML = `<p style="color:var(--text-500);text-align:center;padding:20px">Ошибка: ${escapeHtml(e.message)}</p>`;
      }
    }
  }

  function renderCart() {
    if (state.cart.length === 0) {
      cartContainer.innerHTML = '';
      emptyCart.style.display = 'flex';
      cartSummary.style.display = 'none';
      return;
    }
    emptyCart.style.display = 'none';
    cartSummary.style.display = 'block';

    let total = 0;
    cartContainer.innerHTML = state.cart.map(item => {
      const d = item.dish || {};
      const emoji = categoryEmoji(d.category);
      const itemTotal = (d.price || 0) * (item.quantity || 1);
      total += itemTotal;
      const photoUrl = d.photoUrl;
      const isPhotoUrl = photoUrl && (photoUrl.startsWith('/uploads/') || photoUrl.startsWith('/api/v1/uploads/') || photoUrl.startsWith('http'));

      return `<div class="cart-item" data-id="${item.id}">
        <div class="cart-item-image">${isPhotoUrl ? `<img src="${escapeHtml(photoUrl)}">` : emoji}</div>
        <div class="cart-item-info">
          <div class="cart-item-title">${escapeHtml(d.title || 'Блюдо')}</div>
          <div class="cart-item-price">${formatPrice(d.price)}₽ × ${item.quantity} = ${formatPrice(itemTotal)}₽</div>
          ${d.cook?.name ? `<div style="font-size:12px;color:var(--text-400)">👨‍🍳 ${escapeHtml(d.cook.name)}</div>` : ''}
          <div class="cart-item-qty">
            <button class="qty-btn" data-qty-minus="${item.id}">−</button>
            <span class="qty-value">${item.quantity}</span>
            <button class="qty-btn" data-qty-plus="${item.id}">+</button>
          </div>
        </div>
        <div class="cart-item-remove" data-remove-cart="${item.id}">✕</div>
      </div>`;
    }).join('');

    cartTotal.textContent = formatPrice(total) + '₽';

    cartContainer.querySelectorAll('[data-qty-minus]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        btn.disabled = true;
        const id = btn.dataset.qtyMinus;
        const item = state.cart.find(c => c.id === id);
        try {
          if (item && item.quantity > 1) {
            await api(`/cart/${id}`, { method: 'PUT', body: JSON.stringify({ quantity: item.quantity - 1 }) });
            item.quantity--;
            renderCart();
          }
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    });

    cartContainer.querySelectorAll('[data-qty-plus]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        btn.disabled = true;
        const id = btn.dataset.qtyPlus;
        const item = state.cart.find(c => c.id === id);
        try {
          if (item) {
            await api(`/cart/${id}`, { method: 'PUT', body: JSON.stringify({ quantity: item.quantity + 1 }) });
            item.quantity++;
            renderCart();
          }
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    });

    cartContainer.querySelectorAll('[data-remove-cart]').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        btn.disabled = true;
        const id = btn.dataset.removeCart;
        try {
          await api(`/cart/${id}`, { method: 'DELETE' });
          state.cart = state.cart.filter(c => c.id !== id);
          renderCart();
          toast('Удалено из корзины');
        } catch (err) { toast(err.message, 'error'); }
        finally { btn.disabled = false; }
      });
    });
  }

  // Checkout
  document.getElementById('checkoutBtn')?.addEventListener('click', async () => {
    if (!initData) { toast('Войдите через Telegram', 'warning'); return; }
    if (state.cart.length === 0) { toast('Корзина пуста', 'warning'); return; }
    if (!hasRole()) {
      toast('Сначала выберите роль в профиле', 'warning');
      switchTab('profile');
      return;
    }

    const p = state.profile;
    openModal('Оформление заказа', `
      <div style="display:flex;flex-direction:column;gap:16px">
        <div class="form-group">
          <label>Комментарий к заказу</label>
          <textarea id="orderComment" placeholder="Пожелания, аллергии..." rows="3"></textarea>
        </div>
        <div class="form-group">
          <label>Способ получения</label>
          <select id="orderDelivery">
            <option value="false">🍽 Самовывоз</option>
            <option value="true">🚚 Доставка</option>
          </select>
        </div>
        <div class="form-group" id="orderAddressGroup" style="display:none">
          <label>Адрес доставки</label>
          <input type="text" id="orderAddress" placeholder="Начните вводить: Москва, Тверская 12" value="${escapeHtml(p?.address || '')}" autocomplete="off">
          <div class="addr-results" id="addrResults" style="display:none"></div>
          <small class="form-hint" id="addrHint">Выберите адрес из подсказок — посчитаем расстояние от повара</small>
        </div>
        <div class="form-group">
          <label>Телефон для связи</label>
          <input type="tel" id="orderPhone" placeholder="+7 (999) 123-45-67" value="${escapeHtml(p?.phone || '')}">
        </div>
        <div style="background:var(--surface-3);border-radius:12px;padding:12px;font-size:13px;color:var(--text-500)">
          Итого: <strong style="color:var(--text-900)">${cartTotal.textContent}</strong> • ${state.cart.length} позиций
        </div>
      </div>
    `, `
      <button class="btn btn-secondary" id="checkoutCancel">Отмена</button>
      <button class="btn btn-primary" id="confirmOrder">Подтвердить</button>
    `);

    document.getElementById('checkoutCancel')?.addEventListener('click', closeModal);
    document.getElementById('orderDelivery')?.addEventListener('change', (e) => {
      document.getElementById('orderAddressGroup').style.display = e.target.value === 'true' ? 'block' : 'none';
    });
    const pickedAddress = initAddressSearch();

    const confirmBtn = document.getElementById('confirmOrder');
    confirmBtn?.addEventListener('click', async () => {
      const comment = document.getElementById('orderComment')?.value || '';
      const isDelivery = document.getElementById('orderDelivery')?.value === 'true';
      const phone = document.getElementById('orderPhone')?.value || '';
      const address = document.getElementById('orderAddress')?.value || '';
      if (isDelivery && !address.trim()) {
        toast('Укажите адрес доставки', 'warning');
        return;
      }

      confirmBtn.disabled = true;
      try {
        const created = await api('/orders', {
          method: 'POST',
          body: JSON.stringify({
            items: state.cart.map(c => ({ dishId: c.dish?.id || c.dishId, quantity: c.quantity })),
            comment,
            isDelivery,
            phone,
            address,
            addressLat: pickedAddress?.lat ?? null,
            addressLon: pickedAddress?.lon ?? null
          })
        });
        closeModal();
        state.cart = [];
        renderCart();
        const count = Array.isArray(created) ? created.length : 1;
        toast(`Заказ оформлен${count > 1 ? ` (${count} заказа поварам)` : ''}!`);
        haptic('success');
        switchTab('orders');
      } catch (err) { toast(err.message, 'error'); }
      finally { confirmBtn.disabled = false; }
    });
  });

  // --- Profile ---
  const profileContainer = document.getElementById('profileContainer');

  async function loadProfile() {
    profileContainer.innerHTML = '<div class="loading"><div class="spinner"></div><p>Загружаем...</p></div>';
    try {
      state.profile = await api('/me');
      renderProfile();
      applyRoleUI();
    } catch (e) {
      if (isAuthError(e)) {
        profileContainer.innerHTML = `
          <div class="profile-card">
            <div style="text-align:center;padding:20px">
              <div style="font-size:48px;margin-bottom:12px">👤</div>
              <h3 style="margin-bottom:8px">Войдите через Telegram</h3>
              <p style="color:var(--text-500);margin-bottom:16px">${isWebsite() ? 'Авторизуйтесь через Telegram, чтобы продолжить' : 'Откройте Mini App из @uncle_masha_bot'}</p>
              ${loginLinkHtml()}
            </div>
          </div>
        `;
      } else {
        profileContainer.innerHTML = `<p style="color:var(--text-500);text-align:center;padding:20px">Ошибка: ${escapeHtml(e.message)}</p>`;
      }
    }
  }

  function applyRoleUI() {
    const isCookRole = isCook();
    document.getElementById('fab').classList.toggle('hidden', !(state.tab === 'browse' && isCookRole));
    document.getElementById('createTopBtn').style.display = isCookRole ? 'inline-flex' : 'none';
    const cityEl = document.getElementById('topbarCity');
    if (cityEl) {
      cityEl.textContent = state.profile?.city || (state.profile?.hasLocation ? 'Рядом' : 'Все города');
    }
  }

  function renderProfile() {
    const p = state.profile;
    if (!p) return;

    const initials = (p.firstName || '?').substring(0, 2).toUpperCase();

    // Выбор роли для новых пользователей
    if (p.role === 'none') {
      profileContainer.innerHTML = `
        <div class="profile-card">
          <div style="text-align:center;padding:20px">
            <div style="font-size:48px;margin-bottom:12px">👋</div>
            <h3 style="margin-bottom:8px">Кто вы?</h3>
            <p style="color:var(--text-500);margin-bottom:16px">Выберите роль, чтобы начать пользоваться сервисом</p>
            <div style="display:flex;gap:10px;justify-content:center">
              <button class="btn btn-primary" id="roleClient">🍽 Я клиент</button>
              <button class="btn btn-primary" id="roleCook">👨‍🍳 Я повар</button>
            </div>
          </div>
        </div>`;
      document.getElementById('roleClient').addEventListener('click', () => setRole('client'));
      document.getElementById('roleCook').addEventListener('click', () => setRole('cook'));
      return;
    }

    const cookStatsHtml = isCook() ? `
      <div class="profile-card">
        <h3 style="font-family:'Manrope',sans-serif;font-size:15px;font-weight:800;margin-bottom:12px">📊 Статистика</h3>
        <div id="cookStats"><div class="loading" style="padding:16px"><div class="spinner"></div></div></div>
      </div>` : '';

    const cookToolsHtml = isCook() ? `
      <div class="profile-card">
        <h3 style="font-family:'Manrope',sans-serif;font-size:15px;font-weight:800;margin-bottom:12px">👨‍🍳 Инструменты повара</h3>
        <div style="display:flex;flex-direction:column;gap:10px">
          <button class="btn btn-primary" id="openMyDishes">🍽 Мои блюда</button>
          <button class="btn btn-secondary" id="openPromos">🎟 Промокоды</button>
          <button class="btn btn-secondary" id="openCookSettings">⚙️ Профиль повара</button>
          <button class="btn btn-secondary" id="toggleAccepting">${p.isAcceptingOrders ? '⛔ Отключить приём заказов' : '✅ Включить приём заказов'}</button>
          ${p.hasLocation ? '' : '<button class="btn btn-secondary" id="shareKitchen">📍 Указать кухню (геолокация)</button>'}
        </div>
      </div>` : '';

    profileContainer.innerHTML = `
      <div class="profile-card">
        <div class="profile-header">
          <div class="profile-avatar" style="overflow:hidden;position:relative">
            ${p.photoUrl
              ? `<img src="${escapeHtml(p.photoUrl)}" style="width:100%;height:100%;object-fit:cover">`
              : initials}
          </div>
          <div>
            <div class="profile-name">${escapeHtml(p.firstName || 'Пользователь')}</div>
            <div class="profile-role">${p.role === 'cook' ? '👨‍🍳 Повар' : '🍽 Клиент'}</div>
            ${p.city ? `<div style="font-size:12px;color:var(--text-400);margin-top:2px">📍 ${escapeHtml(p.city)}</div>` : ''}
          </div>
        </div>
        <div class="profile-stats">
          <div class="stat-item">
            <div class="stat-value">${p.balance || 0}</div>
            <div class="stat-label">Баллов</div>
          </div>
          <div class="stat-item">
            <div class="stat-value">${p.rating || '—'}</div>
            <div class="stat-label">Рейтинг</div>
          </div>
          <div class="stat-item">
            <div class="stat-value">${p.ordersCount || 0}</div>
            <div class="stat-label">Заказов</div>
          </div>
        </div>
      </div>
      ${cookStatsHtml}
      ${cookToolsHtml}
      ${p.referralCode ? `
        <div class="profile-card">
          <h3 style="font-family:'Manrope',sans-serif;font-size:15px;font-weight:800;margin-bottom:8px">🎁 Реферальная программа</h3>
          <p style="font-size:13px;color:var(--text-500);margin-bottom:12px">Поделитесь кодом с друзьями и получите 100 баллов за каждого</p>
          <div style="background:var(--surface-3);padding:12px;border-radius:12px;text-align:center;font-size:18px;font-weight:800;letter-spacing:2px">${escapeHtml(p.referralCode)}</div>
        </div>
      ` : ''}
      <div class="profile-card">
        <h3 style="font-family:'Manrope',sans-serif;font-size:15px;font-weight:800;margin-bottom:12px">⚙️ Настройки</h3>
        <div style="display:flex;flex-direction:column;gap:10px">
          <button class="btn btn-secondary" id="openNotifSettings">🔔 Уведомления</button>
          <button class="btn btn-secondary" id="openProfileEdit">✏️ Редактировать профиль</button>
          ${p.hasLocation ? '' : '<button class="btn btn-secondary" id="shareLocation">📍 Поделиться геолокацией</button>'}
          <button class="btn btn-secondary" id="changeRole">🔄 Сменить роль</button>
        </div>
      </div>
      <button class="btn btn-secondary" style="width:100%" onclick="window.open('https://t.me/uncle_masha_bot','_blank')">Открыть Telegram бот</button>
    `;

    document.getElementById('openNotifSettings')?.addEventListener('click', openNotificationSettings);
    document.getElementById('openProfileEdit')?.addEventListener('click', openProfileEdit);
    document.getElementById('shareLocation')?.addEventListener('click', () => requestLocation(true));
    document.getElementById('shareKitchen')?.addEventListener('click', () => requestLocation(true));
    document.getElementById('changeRole')?.addEventListener('click', openRoleSwitch);
    document.getElementById('openMyDishes')?.addEventListener('click', openMyDishes);
    document.getElementById('openPromos')?.addEventListener('click', openPromos);
    document.getElementById('openCookSettings')?.addEventListener('click', openProfileEdit);
    document.getElementById('toggleAccepting')?.addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      try {
        state.profile = await api('/me', { method: 'PUT', body: JSON.stringify({ isAcceptingOrders: !p.isAcceptingOrders }) });
        toast(state.profile.isAcceptingOrders ? 'Приём заказов включён' : 'Приём заказов отключён');
        renderProfile();
      } catch (err) { toast(err.message, 'error'); }
      finally { btn.disabled = false; }
    });

    if (isCook()) loadCookStats();
  }

  async function setRole(role) {
    try {
      state.profile = await api('/me', { method: 'PUT', body: JSON.stringify({ role }) });
      toast(role === 'cook' ? 'Вы стали поваром! Заполните профиль.' : 'Вы клиент!');
      renderProfile();
      applyRoleUI();
      switchTab('browse');
    } catch (err) { toast(err.message, 'error'); }
  }

  function openRoleSwitch() {
    openModal('Смена роли', `
      <p style="color:var(--text-500);margin-bottom:16px">Выберите новую роль. Ваши данные сохранятся.</p>
    `, `
      <button class="btn btn-secondary" id="roleCancel">Отмена</button>
      <button class="btn btn-primary" id="roleClient">🍽 Я клиент</button>
      <button class="btn btn-primary" id="roleCook">👨‍🍳 Я повар</button>
    `);
    document.getElementById('roleCancel')?.addEventListener('click', closeModal);
    document.getElementById('roleClient')?.addEventListener('click', async () => { await setRole('client'); closeModal(); });
    document.getElementById('roleCook')?.addEventListener('click', async () => { await setRole('cook'); closeModal(); });
  }

  async function loadCookStats() {
    const el = document.getElementById('cookStats');
    if (!el) return;
    try {
      const s = await api('/cook-stats');
      el.innerHTML = `
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:10px">
          <div class="stat-item"><div class="stat-value">${s.totalOrders}</div><div class="stat-label">Заказов</div></div>
          <div class="stat-item"><div class="stat-value">${s.activeOrders}</div><div class="stat-label">В работе</div></div>
          <div class="stat-item"><div class="stat-value">${s.todayOrders}</div><div class="stat-label">Сегодня</div></div>
          <div class="stat-item"><div class="stat-value">${formatPrice(s.revenue)}₽</div><div class="stat-label">Выручка</div></div>
          <div class="stat-item"><div class="stat-value">${s.avgRating ? s.avgRating.toFixed(1) : '—'}</div><div class="stat-label">Рейтинг</div></div>
          <div class="stat-item"><div class="stat-value">${s.dishesCount}</div><div class="stat-label">Блюд</div></div>
        </div>`;
    } catch (err) {
      el.innerHTML = `<p style="color:var(--text-500)">Ошибка: ${escapeHtml(err.message)}</p>`;
    }
  }

  async function openNotificationSettings() {
    let settings = { enabled: true, quietHoursStart: null, quietHoursEnd: null };
    try { settings = await api('/notification-settings'); } catch {}
    const presets = [
      { label: '22:00 – 08:00', start: 22, end: 8 },
      { label: '23:00 – 07:00', start: 23, end: 7 },
      { label: '00:00 – 09:00', start: 0, end: 9 }
    ];
    const current = settings.quietHoursStart != null
      ? `${String(settings.quietHoursStart).padStart(2, '0')}:00 – ${String(settings.quietHoursEnd).padStart(2, '0')}:00`
      : 'не заданы';
    openModal('🔔 Уведомления', `
      <div style="display:flex;flex-direction:column;gap:14px">
        <label class="check" style="background:var(--surface-3);border:1px solid var(--border);border-radius:12px">
          <input type="checkbox" id="notifEnabled" ${settings.enabled ? 'checked' : ''}>
          <span>Получать уведомления о новых блюдах поваров</span>
        </label>
        <div class="form-group">
          <label>Тихие часы (сейчас: ${current})</label>
          <div style="display:flex;flex-direction:column;gap:8px">
            ${presets.map(pr => `<button class="btn btn-secondary small" data-quiet="${pr.start}:${pr.end}" style="justify-content:flex-start">🌙 ${pr.label}</button>`).join('')}
            <button class="btn btn-ghost small" id="quietOff" style="justify-content:flex-start">Убрать тихие часы</button>
          </div>
        </div>
        <p style="font-size:12px;color:var(--text-400)">Статусы ваших заказов приходят всегда, независимо от тихих часов.</p>
      </div>
    `, `<button class="btn btn-primary" id="notifSave" style="width:100%">Сохранить</button>`);

    const enabledInput = document.getElementById('notifEnabled');
    let quiet = settings.quietHoursStart != null ? { start: settings.quietHoursStart, end: settings.quietHoursEnd } : null;

    document.querySelectorAll('[data-quiet]').forEach(btn => {
      btn.addEventListener('click', () => {
        const [start, end] = btn.dataset.quiet.split(':').map(Number);
        quiet = { start, end };
        document.querySelectorAll('[data-quiet]').forEach(b => b.classList.remove('btn-primary'));
        btn.classList.add('btn-primary');
      });
    });
    document.getElementById('quietOff')?.addEventListener('click', () => {
      quiet = null;
      document.querySelectorAll('[data-quiet]').forEach(b => b.classList.remove('btn-primary'));
    });

    document.getElementById('notifSave')?.addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      try {
        await api('/notification-settings', {
          method: 'PUT',
          body: JSON.stringify({
            enabled: enabledInput.checked,
            quietHoursStart: quiet ? quiet.start : null,
            quietHoursEnd: quiet ? quiet.end : null,
            clearQuietHours: quiet === null
          })
        });
        closeModal();
        toast('Настройки уведомлений сохранены');
      } catch (err) { toast(err.message, 'error'); }
      finally { btn.disabled = false; }
    });
  }

  function openProfileEdit() {
    const p = state.profile || {};
    const isCookRole = p.role === 'cook';
    openModal('Редактировать профиль', `
      <div style="display:flex;flex-direction:column;gap:14px">
        <div class="form-group">
          <label>Имя</label>
          <input type="text" id="pfName" value="${escapeHtml(p.firstName || '')}" placeholder="Ваше имя">
        </div>
        <div class="form-group">
          <label>Город</label>
          <input type="text" id="pfCity" value="${escapeHtml(p.city || '')}" placeholder="Москва">
        </div>
        <div class="form-group">
          <label>Телефон</label>
          <input type="tel" id="pfPhone" value="${escapeHtml(p.phone || '')}" placeholder="+7 (999) 123-45-67">
        </div>
        <div class="form-group">
          <label>Фото профиля${p.photoUrl ? ' (загружено)' : ''}</label>
          <input type="file" id="pfPhoto" accept="image/*" style="padding:10px">
        </div>
        <div class="form-group">
          <label>Адрес ${isCookRole ? 'кухни' : 'доставки'}</label>
          <input type="text" id="pfAddress" value="${escapeHtml(p.address || '')}" placeholder="г. Москва, ул. Ленина, 5">
        </div>
        ${isCookRole ? `
        <div class="form-group">
          <label>Специализация</label>
          <input type="text" id="pfSpec" value="${escapeHtml(p.specialization || '')}" placeholder="Домашняя кухня, выпечка...">
        </div>
        <div class="form-group">
          <label>О себе</label>
          <textarea id="pfBio" rows="3" placeholder="Расскажите о себе">${escapeHtml(p.bio || '')}</textarea>
        </div>
        <div class="form-group">
          <label>Часы выдачи</label>
          <input type="text" id="pfSchedule" value="${escapeHtml(p.pickupSchedule || '')}" placeholder="10:00–21:00">
        </div>
        <div class="form-group">
          <label>Дни готовки</label>
          <input type="text" id="pfDays" value="${escapeHtml(p.cookingDays || '')}" placeholder="пн, ср, пт, сб">
        </div>
        ` : ''}
      </div>
    `, `
      <button class="btn btn-secondary" id="pfCancel">Отмена</button>
      <button class="btn btn-primary" id="pfSave">Сохранить</button>
    `);

    document.getElementById('pfCancel')?.addEventListener('click', closeModal);
    document.getElementById('pfSave')?.addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      try {
        const body = {
          firstName: document.getElementById('pfName')?.value || '',
          city: document.getElementById('pfCity')?.value || '',
          phone: document.getElementById('pfPhone')?.value || '',
          address: document.getElementById('pfAddress')?.value || ''
        };
        if (isCookRole) {
          body.specialization = document.getElementById('pfSpec')?.value || '';
          body.bio = document.getElementById('pfBio')?.value || '';
          body.pickupSchedule = document.getElementById('pfSchedule')?.value || '';
          body.cookingDays = document.getElementById('pfDays')?.value || '';
        }
        state.profile = await api('/me', { method: 'PUT', body: JSON.stringify(body) });
        // Загружаем фото профиля, если выбрано
        const photoFile = document.getElementById('pfPhoto')?.files?.[0];
        if (photoFile) {
          try {
            const dataUrl = await readAndResizePhoto(photoFile, 512);
            if (dataUrl) {
              state.profile = await api('/me/photo', { method: 'POST', body: JSON.stringify({ photo: dataUrl }) });
            }
          } catch (photoErr) { toast(photoErr.message, 'warning'); }
        }
        closeModal();
        toast('Профиль сохранён');
        renderProfile();
        applyRoleUI();
      } catch (err) { toast(err.message, 'error'); }
      finally { btn.disabled = false; }
    });
  }

  // --- Cook: Мои блюда ---
  async function openMyDishes() {
    openModal('🍽 Мои блюда', `<div class="loading"><div class="spinner"></div><p>Загружаем...</p></div>`, `
      <button class="btn btn-secondary" id="mdClose">Закрыть</button>
      <button class="btn btn-primary" id="mdAdd">＋ Добавить блюдо</button>
    `);
    document.getElementById('mdClose')?.addEventListener('click', closeModal);
    document.getElementById('mdAdd')?.addEventListener('click', () => { closeModal(); openAddDish(); });

    const body = document.getElementById('modalBody');
    try {
      const dishes = await api('/my-dishes');
      if (!dishes.length) {
        body.innerHTML = `<div class="empty-state" style="display:flex"><div class="empty-illust">🍽</div><h3>Блюд пока нет</h3><p>Добавьте первое блюдо!</p></div>`;
        return;
      }
      body.innerHTML = dishes.map(d => `
        <div class="order-card" style="margin-bottom:12px">
          <div style="display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap">
            <div style="font-weight:700;font-size:15px">${escapeHtml(d.title)}</div>
            <div style="display:flex;gap:6px;align-items:center">
              <span class="pill ${d.isToday ? 'pill-today' : ''}" style="${d.isToday ? '' : 'background:var(--surface-3);color:var(--text-500)'}">${d.isToday ? '🔥 Сегодня' : 'Не сегодня'}</span>
              <span class="pill ${d.isActive !== false ? 'pill-fresh' : ''}" style="${d.isActive !== false ? '' : 'background:var(--surface-3);color:var(--text-500)'}">${d.isActive !== false ? 'Активно' : 'Скрыто'}</span>
            </div>
          </div>
          <div style="font-size:13px;color:var(--text-500);margin-top:6px">
            ${categoryLabel(d.category)} • 💰 ${formatPrice(d.price)}₽
            ${d.isToday && d.portionsLeft != null ? ` • Осталось ${d.portionsLeft}` : ''}
          </div>
          <div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap">
            ${d.isToday
              ? `<button class="btn btn-secondary small" data-md-untoday="${d.id}">Убрать с сегодня</button>`
              : `<button class="btn btn-primary small" data-md-today="${d.id}">🔥 На сегодня</button>`}
            <button class="btn btn-secondary small" data-md-toggle="${d.id}">${d.isActive !== false ? 'Скрыть' : 'Показать'}</button>
            <button class="btn btn-secondary small" data-md-edit="${d.id}">✏️ Изменить</button>
            <button class="btn btn-danger small" data-md-delete="${d.id}">🗑</button>
          </div>
        </div>`).join('');

      body.querySelectorAll('[data-md-today]').forEach(btn => {
        btn.addEventListener('click', async () => {
          const id = btn.dataset.mdToday;
          const portions = prompt('Сколько порций готовите сегодня? (пусто — без лимита)', '10');
          const bodyJson = portions && parseInt(portions) > 0 ? { portions: parseInt(portions) } : { portions: null };
          btn.disabled = true;
          try {
            await api(`/dishes/${id}/today`, { method: 'POST', body: JSON.stringify(bodyJson) });
            toast('Блюдо отмечено на сегодня, подписчики уведомлены');
            openMyDishes();
          } catch (err) { toast(err.message, 'error'); }
          finally { btn.disabled = false; }
        });
      });
      body.querySelectorAll('[data-md-untoday]').forEach(btn => {
        btn.addEventListener('click', async () => {
          const id = btn.dataset.mdUntoday;
          btn.disabled = true;
          try {
            await api(`/dishes/${id}/untoday`, { method: 'POST' });
            toast('Убрано с сегодня');
            openMyDishes();
          } catch (err) { toast(err.message, 'error'); }
          finally { btn.disabled = false; }
        });
      });
      body.querySelectorAll('[data-md-toggle]').forEach(btn => {
        btn.addEventListener('click', async () => {
          btn.disabled = true;
          try {
            await api(`/dishes/${btn.dataset.mdToggle}/toggle`, { method: 'POST' });
            openMyDishes();
          } catch (err) { toast(err.message, 'error'); }
          finally { btn.disabled = false; }
        });
      });
      body.querySelectorAll('[data-md-edit]').forEach(btn => {
        btn.addEventListener('click', () => openEditDish(btn.dataset.mdEdit));
      });
      body.querySelectorAll('[data-md-delete]').forEach(btn => {
        btn.addEventListener('click', async () => {
          if (!confirm('Удалить блюдо? Если по нему были заказы, оно будет скрыто.')) return;
          btn.disabled = true;
          try {
            await api(`/dishes/${btn.dataset.mdDelete}`, { method: 'DELETE' });
            toast('Блюдо удалено');
            openMyDishes();
          } catch (err) { toast(err.message, 'error'); }
          finally { btn.disabled = false; }
        });
      });
    } catch (err) {
      body.innerHTML = `<p style="color:var(--text-500);text-align:center;padding:20px">Ошибка: ${escapeHtml(err.message)}</p>`;
    }
  }

  async function openEditDish(id) {
    let dish;
    try { dish = await api(`/dishes/${id}`); } catch (err) { toast(err.message, 'error'); return; }
    openModal('✏️ Изменить блюдо', `
      <div style="display:flex;flex-direction:column;gap:14px">
        <div class="form-group">
          <label>Название</label>
          <input type="text" id="edTitle" value="${escapeHtml(dish.title)}">
        </div>
        <div class="form-group">
          <label>Описание</label>
          <textarea id="edDetails" rows="3">${escapeHtml(dish.details || '')}</textarea>
        </div>
        <div class="form-row">
          <div class="form-group">
            <label>Цена (₽)</label>
            <input type="number" id="edPrice" value="${dish.price}">
          </div>
          <div class="form-group">
            <label>Категория</label>
            <select id="edCategory">
              ${['breakfast', 'lunch', 'dinner', 'dessert', 'drink'].map(c => `<option value="${c}" ${c === dish.category ? 'selected' : ''}>${categoryLabel(c)}</option>`).join('')}
            </select>
          </div>
        </div>
        <div class="form-group">
          <label>Порции (0 — без лимита)</label>
          <input type="number" id="edPortions" value="${dish.portionsTotal ?? ''}" placeholder="10">
        </div>
        <div class="form-group checkbox">
          <input type="checkbox" id="edToday" ${dish.isToday ? 'checked' : ''}>
          <span>🔥 Готовлю сегодня</span>
        </div>
        <div class="form-group">
          <label>Фото блюда${dish.photoUrl ? ' (загружено)' : ''}</label>
          <input type="file" id="edPhoto" accept="image/*" style="padding:10px">
        </div>
      </div>
    `, `
      <button class="btn btn-secondary" id="edCancel">Отмена</button>
      <button class="btn btn-primary" id="edSave">Сохранить</button>
    `);
    document.getElementById('edCancel')?.addEventListener('click', closeModal);
    document.getElementById('edSave')?.addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      try {
        const portionsRaw = parseInt(document.getElementById('edPortions')?.value || '');
        await api(`/dishes/${id}`, {
          method: 'PUT',
          body: JSON.stringify({
            title: document.getElementById('edTitle')?.value || '',
            details: document.getElementById('edDetails')?.value || '',
            price: parseFloat(document.getElementById('edPrice')?.value) || 0,
            category: document.getElementById('edCategory')?.value,
            portionsTotal: isNaN(portionsRaw) ? null : portionsRaw,
            isToday: document.getElementById('edToday')?.checked || false
          })
        });
        const photoFile = document.getElementById('edPhoto')?.files?.[0];
        if (photoFile) {
          try {
            const dataUrl = await readAndResizePhoto(photoFile);
            if (dataUrl) {
              await api(`/dishes/${id}/photo`, { method: 'POST', body: JSON.stringify({ photo: dataUrl }) });
            }
          } catch (photoErr) { toast(photoErr.message, 'warning'); }
        }
        closeModal();
        toast('Блюдо обновлено');
        openMyDishes();
      } catch (err) { toast(err.message, 'error'); }
      finally { btn.disabled = false; }
    });
  }

  // --- Cook: Промокоды ---
  async function openPromos() {
    openModal('🎟 Промокоды', `<div class="loading"><div class="spinner"></div><p>Загружаем...</p></div>`, `
      <button class="btn btn-secondary" id="prClose">Закрыть</button>
      <button class="btn btn-primary" id="prAdd">＋ Создать</button>
    `);
    document.getElementById('prClose')?.addEventListener('click', closeModal);
    document.getElementById('prAdd')?.addEventListener('click', () => {
      const code = prompt('Код промокода (3–20 символов):');
      if (!code) return;
      const discount = prompt('Скидка в процентах (1–90):', '10');
      if (!discount) return;
      api('/promos', { method: 'POST', body: JSON.stringify({ code, discountPercent: parseInt(discount) }) })
        .then(() => { toast('Промокод создан'); openPromos(); })
        .catch(err => toast(err.message, 'error'));
    });

    const body = document.getElementById('modalBody');
    try {
      const promos = await api('/promos');
      if (!promos.length) {
        body.innerHTML = `<div class="empty-state" style="display:flex"><div class="empty-illust">🎟</div><h3>Промокодов нет</h3><p>Создайте первый!</p></div>`;
        return;
      }
      body.innerHTML = promos.map(p => `
        <div class="order-card" style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
          <div>
            <div style="font-weight:800;font-size:15px">${escapeHtml(p.code)} — ${p.discountPercent}%</div>
            <div style="font-size:12px;color:var(--text-400)">${p.isActive ? '✅ активен' : '⛔ отключён'} • использован ${p.usesCount} раз</div>
          </div>
          <button class="btn ${p.isActive ? 'btn-secondary' : 'btn-primary'} small" data-promo-toggle="${p.id}">${p.isActive ? 'Отключить' : 'Включить'}</button>
        </div>`).join('');

      body.querySelectorAll('[data-promo-toggle]').forEach(btn => {
        btn.addEventListener('click', async () => {
          btn.disabled = true;
          try {
            await api(`/promos/${btn.dataset.promoToggle}/toggle`, { method: 'POST' });
            openPromos();
          } catch (err) { toast(err.message, 'error'); }
          finally { btn.disabled = false; }
        });
      });
    } catch (err) {
      body.innerHTML = `<p style="color:var(--text-500);text-align:center;padding:20px">Ошибка: ${escapeHtml(err.message)}</p>`;
    }
  }

  // --- Add Dish (cook only) ---
  function openAddDish() {
    if (!initData) { toast('Войдите через Telegram', 'warning'); return; }
    if (!isCook()) { toast('Только повар может добавлять блюда. Выберите роль в профиле.', 'warning'); switchTab('profile'); return; }

    openModal('Добавить блюдо', `
      <div style="display:flex;flex-direction:column;gap:16px">
        <div class="form-group">
          <label>Название блюда *</label>
          <input type="text" id="dishTitle" placeholder="Борщ украинский" required>
        </div>
        <div class="form-group">
          <label>Описание</label>
          <textarea id="dishDetails" placeholder="Рецепт, состав, особенности..." rows="3"></textarea>
        </div>
        <div class="form-row">
          <div class="form-group">
            <label>Цена (₽) *</label>
            <input type="number" id="dishPrice" placeholder="350" min="0" required>
          </div>
          <div class="form-group">
            <label>Категория</label>
            <select id="dishCategory">
              <option value="lunch">🍲 Обед</option>
              <option value="breakfast">🥞 Завтрак</option>
              <option value="dinner">🍽 Ужин</option>
              <option value="dessert">🍰 Десерт</option>
              <option value="drink">🥤 Напиток</option>
            </select>
          </div>
        </div>
        <div class="form-group">
          <label>Количество порций</label>
          <input type="number" id="dishPortions" placeholder="10" min="1">
        </div>
        <div class="form-group checkbox">
          <input type="checkbox" id="dishToday">
          <span>🔥 Готовлю сегодня</span>
        </div>

        <div class="form-section">
          <div class="form-section-head">
            <span>🍏 КБЖУ</span>
            <small>необязательно — но с ним блюдо выбирают чаще</small>
          </div>
          <div class="form-group">
            <label>Найти продукт в базе</label>
            <input type="text" id="nutriQuery" placeholder="борщ, творог, куриная грудка..." autocomplete="off">
            <div class="nutri-results" id="nutriResults" style="display:none"></div>
          </div>
          <div class="form-row">
            <div class="form-group">
              <label>Ккал на 100 г</label>
              <input type="number" id="dishKcal" min="0" max="900" step="0.1" placeholder="325">
            </div>
            <div class="form-group">
              <label>Белки на 100 г</label>
              <input type="number" id="dishProtein" min="0" max="100" step="0.1" placeholder="7">
            </div>
          </div>
          <div class="form-row">
            <div class="form-group">
              <label>Жиры на 100 г</label>
              <input type="number" id="dishFat" min="0" max="100" step="0.1" placeholder="9.5">
            </div>
            <div class="form-group">
              <label>Углеводы на 100 г</label>
              <input type="number" id="dishCarbs" min="0" max="100" step="0.1" placeholder="53">
            </div>
          </div>
          <div class="form-group">
            <label>Вес порции, г</label>
            <input type="number" id="dishPortionWeight" min="1" max="5000" placeholder="350">
            <small class="form-hint">Если указать вес — покажем КБЖУ на порцию, а не на 100 г</small>
          </div>
        </div>
        <div class="form-group">
          <label>Фото блюда</label>
          <input type="file" id="dishPhoto" accept="image/*" style="padding:10px">
        </div>
      </div>
    `, `
      <button class="btn btn-secondary" id="addDishCancel">Отмена</button>
      <button class="btn btn-primary" id="saveDish">Добавить</button>
    `);

    initNutritionSearch();

    document.getElementById('addDishCancel')?.addEventListener('click', closeModal);
    const saveBtn = document.getElementById('saveDish');
    saveBtn?.addEventListener('click', async () => {
      const title = document.getElementById('dishTitle')?.value?.trim();
      const price = parseFloat(document.getElementById('dishPrice')?.value);

      if (!title) { toast('Введите название', 'warning'); return; }
      if (!price || price <= 0) { toast('Введите цену', 'warning'); return; }

      saveBtn.disabled = true;
      try {
        const created = await api('/dishes', {
          method: 'POST',
          body: JSON.stringify({
            title,
            details: document.getElementById('dishDetails')?.value || '',
            price,
            category: document.getElementById('dishCategory')?.value || 'lunch',
            portionsTotal: parseInt(document.getElementById('dishPortions')?.value) || null,
            isToday: document.getElementById('dishToday')?.checked || false,
            ...readNutritionForm()
          })
        });
        // Загружаем фото, если выбрано
        const photoFile = document.getElementById('dishPhoto')?.files?.[0];
        if (photoFile) {
          try {
            const dataUrl = await readAndResizePhoto(photoFile);
            if (dataUrl) {
              await api(`/dishes/${created.id}/photo`, { method: 'POST', body: JSON.stringify({ photo: dataUrl }) });
            }
          } catch (photoErr) { toast(photoErr.message, 'warning'); }
        }
        closeModal();
        toast('Блюдо добавлено!');
        haptic('success');
        loadBrowse(true);
      } catch (err) { toast(err.message, 'error'); }
      finally { saveBtn.disabled = false; }
    });
  }

  // --- Location ---
  function sendLocationToServer(latitude, longitude) {
    api('/location', { method: 'PUT', body: JSON.stringify({ latitude, longitude }) })
      .then(async () => {
        toast('Геолокация сохранена');
        state.profile = await api('/me').catch(() => state.profile);
        applyRoleUI();
        loadBrowse(true);
      })
      .catch(() => {});
  }

  function requestLocation(manual = false) {
    if (!initData) { if (manual) toast('Войдите через Telegram', 'warning'); return; }
    try {
      const tgLoc = tg?.LocationManager;
      if (tgLoc && tgLoc.isInited) {
        tgLoc.getLocation((data) => {
          if (data && data.latitude) sendLocationToServer(data.latitude, data.longitude);
          else if (manual) toast('Не удалось получить геолокацию', 'warning');
        });
        return;
      }
    } catch {}
    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(
        (pos) => sendLocationToServer(pos.coords.latitude, pos.coords.longitude),
        () => { if (manual) toast('Доступ к геолокации запрещён', 'warning'); },
        { enableHighAccuracy: false, timeout: 10000, maximumAge: 300000 }
      );
    } else if (manual) {
      toast('Геолокация недоступна в этом браузере', 'warning');
    }
  }

  // --- Load cities ---
  async function loadCities() {
    try {
      const cities = await api('/cities');
      const select = document.getElementById('sidebarCity');
      if (select && cities) {
        cities.forEach(city => {
          const opt = document.createElement('option');
          opt.value = city;
          opt.textContent = city;
          select.appendChild(opt);
        });
      }
    } catch {}
  }
  loadCities();

  // --- Эффекты «Авроры»: свечение фона, плавно следующее за курсором ---
  (function initAuroraCursor() {
    if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    try {
      const el = document.createElement('div');
      el.className = 'aurora-cursor';
      document.body.appendChild(el);
      let tx = window.innerWidth / 2, ty = window.innerHeight * 0.35;
      let gx = tx, gy = ty;
      document.addEventListener('mousemove', (e) => { tx = e.clientX; ty = e.clientY; }, { passive: true });
      (function loop() {
        gx += (tx - gx) * 0.07;
        gy += (ty - gy) * 0.07;
        el.style.transform = 'translate3d(' + (gx - 360) + 'px, ' + (gy - 360) + 'px, 0)';
        requestAnimationFrame(loop);
      })();
    } catch (e) {}
  })();

  // --- Init ---
  (async function init() {
    // Ждём асинхронно загружаемый Telegram SDK (до 3 секунд),
    // чтобы Mini App получил initData и тему.
    for (let i = 0; i < 30 && !tg; i++) {
      await new Promise(r => setTimeout(r, 100));
      tg = window.Telegram?.WebApp;
    }
    if (tg) {
      try { tg.ready(); } catch {}
      try { tg.expand(); } catch {}
      try { tg.enableClosingConfirmation?.(); } catch {}
      initData = tg.initData || initData;
      if (tg.onEvent) {
        tg.onEvent('themeChanged', () => {
          applyTheme();
        });
      }
      applyTheme();
    }
    if (!initData) {
      document.documentElement.classList.add('is-website');
    }

    try {
      state.profile = await api('/me');
      // Тихо синхронизируем часовой пояс пользователя (для тихих часов)
      const offset = -new Date().getTimezoneOffset();
      if (state.profile && state.profile.utcOffsetMinutes !== offset) {
        api('/me', { method: 'PUT', body: JSON.stringify({ utcOffsetMinutes: offset }) })
          .then(p => { state.profile = p; })
          .catch(() => {});
      }
    } catch (e) {
      state.profile = null;
    }
    applyRoleUI();
    switchTab('browse');
    window.__POVAR_READY = true;
    // Тихо запрашиваем геолокацию для «рядом», если её ещё нет
    if (initData && state.profile && state.profile.role === 'client' && !state.profile.hasLocation) {
      requestLocation(false);
    }
  })();
})();
