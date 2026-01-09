/**
 * ОЧАГЪ | Дровяная пицца
 * Интерактивная логика главной страницы
 */

// Состояние корзины
const cart = {
    items: [],
    total: 0,

    addItem(product) {
        const existingItem = this.items.find(item => item.id === product.id);

        if (existingItem) {
            existingItem.quantity += 1;
        } else {
            this.items.push({
                ...product,
                quantity: 1
            });
        }

        this.calculateTotal();
        this.saveToStorage();
        this.updateUI();
    },

    removeItem(productId) {
        this.items = this.items.filter(item => item.id !== productId);
        this.calculateTotal();
        this.saveToStorage();
        this.updateUI();
    },

    updateQuantity(productId, delta) {
        const item = this.items.find(item => item.id === productId);

        if (item) {
            item.quantity += delta;

            if (item.quantity <= 0) {
                this.removeItem(productId);
            } else {
                this.calculateTotal();
                this.saveToStorage();
                this.updateUI();
            }
        }
    },

    calculateTotal() {
        this.total = this.items.reduce((sum, item) => {
            return sum + (item.price * item.quantity);
        }, 0);
    },

    saveToStorage() {
        localStorage.setItem('ochag_cart', JSON.stringify({
            items: this.items,
            total: this.total
        }));
    },

    loadFromStorage() {
        const saved = localStorage.getItem('ochag_cart');

        if (saved) {
            const data = JSON.parse(saved);
            this.items = data.items || [];
            this.total = data.total || 0;
        }
    },

    updateUI() {
        this.updateCartCount();
        this.renderCartItems();
        this.updateTotal();
    },

    updateCartCount() {
        const count = this.items.reduce((sum, item) => sum + item.quantity, 0);
        const cartCount = document.getElementById('cartCount');

        if (count > 0) {
            cartCount.textContent = count;
            cartCount.classList.add('active', 'pulse');

            setTimeout(() => {
                cartCount.classList.remove('pulse');
            }, 500);
        } else {
            cartCount.classList.remove('active');
        }
    },

    renderCartItems() {
        const cartItemsContainer = document.getElementById('cartItems');

        if (this.items.length === 0) {
            cartItemsContainer.innerHTML = `
                <div class="cart-empty">
                    <p>Корзина пуста</p>
                    <span>Добавьте пиццу из меню</span>
                </div>
            `;
            return;
        }

        cartItemsContainer.innerHTML = this.items.map(item => `
            <div class="cart-item" data-id="${item.id}">
                <div class="cart-item-image">
                    <img src="${item.image || getProductImage(item.id)}" alt="${item.name}">
                </div>
                <div class="cart-item-info">
                    <div class="cart-item-name">${item.name}</div>
                    <div class="cart-item-price">${item.price} ₽</div>
                    <div class="cart-item-controls">
                        <button class="qty-btn" onclick="cart.updateQuantity(${item.id}, -1)">−</button>
                        <span class="qty-value">${item.quantity}</span>
                        <button class="qty-btn" onclick="cart.updateQuantity(${item.id}, 1)">+</button>
                        <button class="remove-btn" onclick="cart.removeItem(${item.id})">Удалить</button>
                    </div>
                </div>
            </div>
        `).join('');
    },

    updateTotal() {
        const totalElement = document.getElementById('totalPrice');
        totalElement.textContent = `${this.total.toLocaleString('ru-RU')} ₽`;
    },

    clear() {
        this.items = [];
        this.total = 0;
        this.saveToStorage();
        this.updateUI();
    }
};

// Получение изображения товара по ID
function getProductImage(id) {
    const images = {
        1: 'https://images.unsplash.com/photo-1628840042765-356cda07504e?w=400&h=300&fit=crop',
        2: 'https://images.unsplash.com/photo-1593560708920-61dd98c46a4e?w=400&h=300&fit=crop',
        3: 'https://images.unsplash.com/photo-1574071318508-1cdbab80d002?w=400&h=300&fit=crop',
        4: 'https://images.unsplash.com/photo-1565299624946-b28f40a0ae38?w=400&h=300&fit=crop',
        5: 'https://images.unsplash.com/photo-1604382354936-07c5d9983bd3?w=400&h=300&fit=crop',
        6: 'https://images.unsplash.com/photo-1513104890138-7c749659a591?w=400&h=300&fit=crop'
    };

    return images[id] || images[6];
}

// UI функции
function showToast(message = 'Добавлено в корзину') {
    const toast = document.getElementById('toast');
    toast.querySelector('.toast-text').textContent = message;

    toast.classList.add('active');

    setTimeout(() => {
        toast.classList.remove('active');
    }, 2500);
}

function toggleCart() {
    const overlay = document.getElementById('cartOverlay');
    const sidebar = document.getElementById('cartSidebar');

    overlay.classList.toggle('active');
    sidebar.classList.toggle('active');

    document.body.style.overflow = sidebar.classList.contains('active') ? 'hidden' : '';
}

function closeCart() {
    const overlay = document.getElementById('cartOverlay');
    const sidebar = document.getElementById('cartSidebar');

    overlay.classList.remove('active');
    sidebar.classList.remove('active');
    document.body.style.overflow = '';
}

// Фильтрация товаров
function initFilters() {
    const filterButtons = document.querySelectorAll('.filter-btn');
    const productCards = document.querySelectorAll('.product-card');

    filterButtons.forEach(button => {
        button.addEventListener('click', () => {
            // Обновляем активное состояние кнопок
            filterButtons.forEach(btn => btn.classList.remove('active'));
            button.classList.add('active');

            const filter = button.dataset.filter;

            // Фильтруем карточки
            productCards.forEach((card, index) => {
                const category = card.dataset.category;

                if (filter === 'all' || category === filter) {
                    card.classList.remove('hidden');

                    // Добавляем задержку для эффекта каскада
                    setTimeout(() => {
                        card.classList.add('visible');
                    }, index * 100);
                } else {
                    card.classList.remove('visible');

                    setTimeout(() => {
                        card.classList.add('hidden');
                    }, 300);
                }
            });
        });
    });
}

// Анимация появления карточек при скролле
function initScrollAnimations() {
    const observerOptions = {
        threshold: 0.1,
        rootMargin: '0px 0px -50px 0px'
    };

    const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry, index) => {
            if (entry.isIntersecting) {
                setTimeout(() => {
                    entry.target.classList.add('visible');
                }, index * 100);
            }
        });
    }, observerOptions);

    const productCards = document.querySelectorAll('.product-card');

    productCards.forEach(card => {
        observer.observe(card);
    });
}

// Плавный скролл для навигации
function initSmoothScroll() {
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function(e) {
            e.preventDefault();
            const target = document.querySelector(this.getAttribute('href'));

            if (target) {
                const headerOffset = 100;
                const elementPosition = target.getBoundingClientRect().top;
                const offsetPosition = elementPosition + window.pageYOffset - headerOffset;

                window.scrollTo({
                    top: offsetPosition,
                    behavior: 'smooth'
                });
            }
        });
    });
}

// Инициализация обработчиков событий
function initEventListeners() {
    // Открытие/закрытие корзины
    document.getElementById('cartBtn').addEventListener('click', toggleCart);
    document.getElementById('cartClose').addEventListener('click', closeCart);
    document.getElementById('cartOverlay').addEventListener('click', closeCart);

    // Добавление товаров в корзину
    document.querySelectorAll('.add-btn').forEach(button => {
        button.addEventListener('click', function() {
            const product = {
                id: parseInt(this.dataset.id),
                name: this.dataset.name,
                price: parseInt(this.dataset.price)
            };

            cart.addItem(product);

            // Визуальный эффект кнопки
            this.classList.add('added');
            this.querySelector('span').textContent = 'ДОБАВЛЕНО';

            setTimeout(() => {
                this.classList.remove('added');
                this.querySelector('span').textContent = 'В КОРЗИНУ';
            }, 1500);

            showToast();
        });
    });

    // Оформление заказа
    document.getElementById('checkoutBtn').addEventListener('click', () => {
        if (cart.items.length > 0) {
            alert('Спасибо за заказ! Мы свяжемся с вами в ближайшее время для подтверждения.\n\nОЧАГЪ — традиции дровяного очага');

            cart.clear();
            closeCart();
        } else {
            showToast('Добавьте пиццу в корзину');
        }
    });

    // Закрытие корзины по Escape
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            closeCart();
        }
    });
}

// Анимация огня в логотипе
function initFireAnimation() {
    const logoFire = document.querySelector('.logo-fire');

    if (logoFire) {
        // Добавляем дополнительные эффекты при наведении
        logoFire.addEventListener('mouseenter', () => {
            logoFire.style.transform = 'scale(1.2)';
        });

        logoFire.addEventListener('mouseleave', () => {
            logoFire.style.transform = 'scale(1)';
        });
    }
}

// Параллакс эффект для героя
function initParallax() {
    const hero = document.querySelector('.hero');
    const heroContent = document.querySelector('.hero-content');

    if (hero && heroContent) {
        window.addEventListener('scroll', () => {
            const scrolled = window.pageYOffset;

            if (scrolled < window.innerHeight) {
                heroContent.style.transform = `translateY(${scrolled * 0.3}px)`;
                heroContent.style.opacity = 1 - (scrolled / window.innerHeight);
            }
        });
    }
}

// Инициализация карты (интерактивный элемент)
function initMap() {
    const mapContainer = document.querySelector('.map');

    if (mapContainer) {
        // Имитация интерактивной карты
        mapContainer.addEventListener('click', () => {
            // В реальном проекте здесь был бы код инициализации карты
            // (Яндекс.Карты, Google Maps, 2GIS и т.д.)

            const mapText = mapContainer.querySelector('.map-text');

            if (mapText) {
                mapText.style.opacity = '0';

                setTimeout(() => {
                    mapText.innerHTML = '📍 Открыть в картах';
                    mapText.style.cursor = 'pointer';
                    mapText.style.opacity = '1';
                }, 300);
            }
        });
    }
}

// Анимация счётчиков
function animateCounters() {
    const counters = document.querySelectorAll('.feature-title');

    const observerOptions = {
        threshold: 0.5
    };

    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.style.animation = 'fadeInUp 0.8s ease-out forwards';
            }
        });
    }, observerOptions);

    counters.forEach(counter => {
        observer.observe(counter);
    });
}

// Инициализация при загрузке страницы
document.addEventListener('DOMContentLoaded', () => {
    // Загружаем корзину из localStorage
    cart.loadFromStorage();
    cart.updateUI();

    // Инициализируем все функции
    initFilters();
    initScrollAnimations();
    initSmoothScroll();
    initEventListeners();
    initFireAnimation();
    initParallax();
    initMap();
    animateCounters();

    // Добавляем класс visible для первых карточек
    setTimeout(() => {
        document.querySelectorAll('.product-card').forEach((card, index) => {
            setTimeout(() => {
                card.classList.add('visible');
            }, index * 150);
        });
    }, 500);

    console.log('ОЧАГЪ — Дровяная пицца загружен');
    console.log('Разработано с любовью к традициям');
});
