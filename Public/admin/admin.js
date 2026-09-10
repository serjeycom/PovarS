(function() {
    'use strict';
    const API = '/api/v1/admin';
    let allUsers = [], allDishes = [], allOrders = [];

    // Токен админки: спрашиваем один раз и храним в localStorage
    function getToken() {
        let token = localStorage.getItem('adminToken');
        if (!token) {
            token = prompt('Введите ADMIN_TOKEN для доступа к админ-панели:');
            if (token) localStorage.setItem('adminToken', token);
        }
        return token || '';
    }

    async function api(path, opts = {}) {
        const res = await fetch(API + path, {
            ...opts,
            headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + getToken(),
                ...opts.headers
            }
        });
        if (res.status === 401 || res.status === 503) {
            localStorage.removeItem('adminToken');
            const e = await res.text();
            throw new Error((res.status === 401 ? 'Неверный токен: ' : '') + e || res.statusText);
        }
        if (!res.ok) { const e = await res.text(); throw new Error(e || res.statusText); }
        if (res.status === 204) return null;
        return res.json();
    }

    function toast(msg, type = 'success') {
        const t = document.createElement('div');
        t.className = 'toast ' + type;
        t.textContent = msg;
        document.body.appendChild(t);
        setTimeout(() => t.remove(), 3000);
    }

    window.closeModal = function(id) { document.getElementById(id).classList.remove('open'); };
    function openModal(id) { document.getElementById(id).classList.add('open'); }
    function esc(s) { const d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; }

    const statusLabels = { new:'Новый', accepted:'Принят', cooking:'Готовится', ready:'Готов', on_the_way:'В пути', onTheWay:'В пути', delivered:'Доставлен', cancelled:'Отменён' };
    const typeLabels = { breakfast:'Завтрак', lunch:'Обед', dinner:'Ужин', dessert:'Десерт', drink:'Напиток' };

    function statusPill(s) { return `<span class="pill pill-${s}">${statusLabels[s]||s}</span>`; }
    function rolePill(r) { return r==='cook' ? '<span class="pill pill-cook">Повар</span>' : '<span class="pill pill-client">Клиент</span>'; }
    function activePill(a) { return a ? '<span class="pill pill-active">●</span>' : '<span class="pill pill-inactive">●</span>'; }
    function starsHtml(r) { return r ? '<span class="stars">' + '★'.repeat(r) + '☆'.repeat(5-r) + '</span>' : '—'; }
    function shortId(id) { return (id||'').substring(0,8); }
    function dateStr(d) { return d ? d.replace('T',' ').substring(0,16) : '—'; }

    // --- Subtabs ---
    document.querySelectorAll('.subtab').forEach(tab => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('.subtab').forEach(t => t.classList.remove('active'));
            tab.classList.add('active');
            document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
            document.getElementById('tab' + tab.dataset.tab.charAt(0).toUpperCase() + tab.dataset.tab.slice(1)).classList.add('active');
            loadSection(tab.dataset.tab);
        });
    });

    function loadSection(tab) {
        if (tab === 'aorders') loadOrders();
        else if (tab === 'ausers') loadUsers();
        else if (tab === 'adishes') loadDishes();
        else if (tab === 'abroadcast') { /* форма уже на странице */ }
    }

    // --- Broadcast (реклама в чат бота) ---
    document.getElementById('bcSend').addEventListener('click', async () => {
        const text = document.getElementById('bcText').value.trim();
        if (!text) { toast('Введите текст сообщения', 'error'); return; }
        const btn = document.getElementById('bcSend');
        const status = document.getElementById('bcStatus');
        btn.disabled = true;
        status.textContent = 'Отправляем...';
        try {
            const r = await api('/broadcast', {
                method: 'POST',
                body: JSON.stringify({
                    text,
                    audience: document.getElementById('bcAudience').value,
                    respectQuietHours: document.getElementById('bcQuiet').checked
                })
            });
            toast(`Рассылка завершена: отправлено ${r.sent}, пропущено (тихие часы) ${r.skipped}, ошибок ${r.failed}`);
            status.textContent = `Всего ${r.total}: отправлено ${r.sent}, пропущено ${r.skipped}, ошибок ${r.failed}`;
        } catch (e) {
            toast(e.message, 'error');
            status.textContent = '';
        } finally {
            btn.disabled = false;
        }
    });

    // --- Stats ---
    async function loadStats() {
        try {
            const s = await api('/stats');
            document.getElementById('statsGrid').innerHTML = `
                <div class="stat blue"><div class="label">Пользователей</div><div class="value">${s.totalUsers}</div></div>
                <div class="stat indigo"><div class="label">Клиентов</div><div class="value">${s.totalClients}</div></div>
                <div class="stat sky"><div class="label">Поваров</div><div class="value">${s.totalCooks}</div></div>
                <div class="stat green"><div class="label">Блюд</div><div class="value">${s.totalDishes}</div></div>
                <div class="stat yellow"><div class="label">Заказов</div><div class="value">${s.totalOrders}</div></div>
                <div class="stat emerald"><div class="label">Выручка</div><div class="value">${Math.round(s.totalRevenue).toLocaleString()}₽</div></div>
                <div class="stat purple"><div class="label">Средний чек</div><div class="value">${Math.round(s.avgOrderPrice)}₽</div></div>
                <div class="stat red"><div class="label">Отменено</div><div class="value">${s.cancelledOrders ?? 0}</div></div>
            `;
        } catch(e) { toast(e.message, 'error'); }
    }

    document.getElementById('seedBtn').addEventListener('click', async () => {
        if (!confirm('Создать моковые данные?')) return;
        try { toast(await api('/seed', { method: 'POST' })); loadStats(); } catch(e) { toast(e.message, 'error'); }
    });
    document.getElementById('refreshBtn').addEventListener('click', () => { loadStats(); loadSection(document.querySelector('.subtab.active').dataset.tab); });
    document.getElementById('tokenBtn').addEventListener('click', () => {
        localStorage.removeItem('adminToken');
        toast('Токен сброшен', 'warning');
        setTimeout(() => location.reload(), 500);
    });

    // --- Users ---
    async function loadUsers() {
        try { allUsers = await api('/users'); renderUsers(allUsers); } catch(e) { toast(e.message, 'error'); }
    }
    function renderUsers(users) {
        document.getElementById('usersBody').innerHTML = users.length ? users.map(u => `
            <tr>
                <td class="id">${shortId(u.id)}</td>
                <td><strong>${esc(u.firstName)} ${esc(u.lastName||'')}</strong>${u.username?'<br><span style="color:var(--text-3);font-size:11px">@'+esc(u.username)+'</span>':''}</td>
                <td>${rolePill(u.role)}</td>
                <td>${esc(u.city||'—')}</td>
                <td>${u.balance??0}₽</td>
                <td style="font-size:12px;color:var(--text-3)">${dateStr(u.createdAt)}</td>
                <td>
                    <button class="btn btn-ghost btn-sm" onclick="editUser('${u.id}')">✏️</button>
                    <button class="btn btn-danger btn-sm" onclick="deleteUser('${u.id}','${esc(u.firstName)}')">🗑</button>
                </td>
            </tr>
        `).join('') : '<tr><td colspan="7" class="empty"><div class="empty-icon">👥</div>Пусто</td></tr>';
    }

    document.getElementById('userSearch').addEventListener('input', function() {
        const q = this.value.toLowerCase();
        const role = document.getElementById('userRoleFilter').value;
        renderUsers(allUsers.filter(u => {
            if (role && u.role !== role) return false;
            return (u.firstName+' '+(u.lastName||'')+' '+(u.city||'')+' '+(u.username||'')).toLowerCase().includes(q);
        }));
    });
    document.getElementById('userRoleFilter').addEventListener('change', function() {
        document.getElementById('userSearch').dispatchEvent(new Event('input'));
    });

    window.editUser = function(id) {
        const u = allUsers.find(x => x.id === id); if (!u) return;
        document.getElementById('editUserId').value = u.id;
        document.getElementById('editUserFirstName').value = u.firstName||'';
        document.getElementById('editUserLastName').value = u.lastName||'';
        document.getElementById('editUserPhone').value = u.phone||'';
        document.getElementById('editUserRole').value = u.role||'client';
        document.getElementById('editUserCity').value = u.city||'';
        document.getElementById('editUserBio').value = u.bio||'';
        document.getElementById('editUserSpec').value = u.specialization||'';
        document.getElementById('editUserAddress').value = u.address||'';
        document.getElementById('editUserBalance').value = u.balance??0;
        openModal('editUserModal');
    };
    document.getElementById('saveUserBtn').addEventListener('click', async () => {
        const id = document.getElementById('editUserId').value;
        try {
            await api('/users/'+id, { method:'PUT', body: JSON.stringify({
                firstName: document.getElementById('editUserFirstName').value,
                lastName: document.getElementById('editUserLastName').value,
                phone: document.getElementById('editUserPhone').value,
                role: document.getElementById('editUserRole').value,
                city: document.getElementById('editUserCity').value,
                bio: document.getElementById('editUserBio').value,
                specialization: document.getElementById('editUserSpec').value,
                address: document.getElementById('editUserAddress').value,
                balance: parseInt(document.getElementById('editUserBalance').value)||0
            })});
            closeModal('editUserModal'); toast('Сохранено'); loadUsers();
        } catch(e) { toast(e.message, 'error'); }
    });
    window.deleteUser = async function(id, name) {
        if (!confirm('Удалить '+name+'?')) return;
        try { await api('/users/'+id, {method:'DELETE'}); toast('Удалён'); loadUsers(); } catch(e) { toast(e.message, 'error'); }
    };

    // --- Dishes ---
    async function loadDishes() {
        try { allDishes = await api('/dishes'); renderDishes(allDishes); } catch(e) { toast(e.message, 'error'); }
    }
    function renderDishes(dishes) {
        document.getElementById('dishesBody').innerHTML = dishes.length ? dishes.map(d => `
            <tr>
                <td><strong>${esc(d.title)}</strong></td>
                <td>${esc(d.cookName||'—')}</td>
                <td>${Math.round(d.price)}₽</td>
                <td>${typeLabels[d.dishType]||d.dishType||'—'}</td>
                <td>${d.portionsLeft??'—'} / ${d.portionsTotal??'—'}</td>
                <td>${activePill(d.isActive)}</td>
                <td>
                    <button class="btn btn-ghost btn-sm" onclick="editDish('${d.id}')">✏️</button>
                    <button class="btn btn-danger btn-sm" onclick="deleteDish('${d.id}','${esc(d.title)}')">🗑</button>
                </td>
            </tr>
        `).join('') : '<tr><td colspan="7" class="empty"><div class="empty-icon">🍽</div>Пусто</td></tr>';
    }

    document.getElementById('dishSearch').addEventListener('input', function() {
        const q = this.value.toLowerCase();
        const type = document.getElementById('dishTypeFilter').value;
        renderDishes(allDishes.filter(d => {
            if (type && d.dishType !== type) return false;
            return (d.title+' '+(d.cookName||'')).toLowerCase().includes(q);
        }));
    });
    document.getElementById('dishTypeFilter').addEventListener('change', function() {
        document.getElementById('dishSearch').dispatchEvent(new Event('input'));
    });

    window.editDish = function(id) {
        const d = allDishes.find(x => x.id === id); if (!d) return;
        document.getElementById('editDishId').value = d.id;
        document.getElementById('editDishTitle').value = d.title||'';
        document.getElementById('editDishDetails').value = d.details||'';
        document.getElementById('editDishPrice').value = d.price||0;
        document.getElementById('editDishType').value = d.dishType||'lunch';
        document.getElementById('editDishPortions').value = d.portionsTotal??'';
        document.getElementById('editDishPortionsLeft').value = d.portionsLeft??'';
        document.getElementById('editDishActive').value = d.isActive?'true':'false';
        openModal('editDishModal');
    };
    document.getElementById('saveDishBtn').addEventListener('click', async () => {
        const id = document.getElementById('editDishId').value;
        try {
            await api('/dishes/'+id, { method:'PUT', body: JSON.stringify({
                title: document.getElementById('editDishTitle').value,
                details: document.getElementById('editDishDetails').value,
                price: parseFloat(document.getElementById('editDishPrice').value)||0,
                dishType: document.getElementById('editDishType').value,
                portionsTotal: parseInt(document.getElementById('editDishPortions').value)||null,
                portionsLeft: parseInt(document.getElementById('editDishPortionsLeft').value)||null,
                isActive: document.getElementById('editDishActive').value==='true'
            })});
            closeModal('editDishModal'); toast('Сохранено'); loadDishes();
        } catch(e) { toast(e.message, 'error'); }
    });
    window.deleteDish = async function(id, title) {
        if (!confirm('Удалить «'+title+'»?')) return;
        try { await api('/dishes/'+id, {method:'DELETE'}); toast('Удалено'); loadDishes(); } catch(e) { toast(e.message, 'error'); }
    };

    // --- Orders ---
    async function loadOrders() {
        try { allOrders = await api('/orders'); renderOrders(allOrders); } catch(e) { toast(e.message, 'error'); }
    }
    function renderOrders(orders) {
        document.getElementById('ordersBody').innerHTML = orders.length ? orders.map(o => `
            <tr>
                <td class="id">${shortId(o.id)}</td>
                <td>${esc(o.dishTitle||'—')}</td>
                <td>${esc(o.clientName||'—')}</td>
                <td>${esc(o.cookName||'—')}</td>
                <td><strong>${Math.round(o.totalPrice)}₽</strong> × ${o.quantity}</td>
                <td>${statusPill(o.status)}</td>
                <td>${o.rating ? starsHtml(o.rating) : '—'}</td>
                <td>
                    <button class="btn btn-ghost btn-sm" onclick="editOrder('${o.id}')">✏️</button>
                    <button class="btn btn-danger btn-sm" onclick="deleteOrder('${o.id}')">🗑</button>
                </td>
            </tr>
        `).join('') : '<tr><td colspan="8" class="empty"><div class="empty-icon">📋</div>Пусто</td></tr>';
    }

    document.getElementById('orderSearch').addEventListener('input', function() {
        const q = this.value.toLowerCase();
        const status = document.getElementById('orderStatusFilter').value;
        renderOrders(allOrders.filter(o => {
            if (status && o.status !== status) return false;
            return ((o.dishTitle||'')+' '+(o.clientName||'')+' '+(o.cookName||'')).toLowerCase().includes(q);
        }));
    });
    document.getElementById('orderStatusFilter').addEventListener('change', function() {
        document.getElementById('orderSearch').dispatchEvent(new Event('input'));
    });

    window.editOrder = function(id) {
        const o = allOrders.find(x => x.id === id); if (!o) return;
        document.getElementById('editOrderId').value = o.id;
        document.getElementById('editOrderStatus').value = o.status;
        document.getElementById('editOrderComment').value = o.comment||'';
        document.getElementById('editOrderRating').value = o.rating||'';
        openModal('editOrderModal');
    };
    document.getElementById('saveOrderBtn').addEventListener('click', async () => {
        const id = document.getElementById('editOrderId').value;
        try {
            await api('/orders/'+id, { method:'PUT', body: JSON.stringify({
                status: document.getElementById('editOrderStatus').value,
                comment: document.getElementById('editOrderComment').value,
                rating: parseInt(document.getElementById('editOrderRating').value)||null
            })});
            closeModal('editOrderModal'); toast('Сохранено'); loadOrders();
        } catch(e) { toast(e.message, 'error'); }
    });
    window.deleteOrder = async function(id) {
        if (!confirm('Удалить заказ?')) return;
        try { await api('/orders/'+id, {method:'DELETE'}); toast('Удалён'); loadOrders(); } catch(e) { toast(e.message, 'error'); }
    };

    // Init
    loadStats();
    loadOrders();
})();
