(() => {
    'use strict';

    const root = document.getElementById('progress-root');

    const ringLayout =
        document.getElementById('ring-layout');

    const barLayout =
        document.getElementById('bar-layout');

    const ringValue =
        document.getElementById('ring-value');

    const ringPercent =
        document.getElementById('ring-percent');

    const barValue =
        document.getElementById('bar-value');

    const label =
        document.getElementById('progress-label');

    const cancelHint =
        document.getElementById('cancel-hint');

    const RING_RADIUS = 52;
    const RING_CIRCUMFERENCE =
        2 * Math.PI * RING_RADIUS;

    let currentTaskId = null;
    let startedAt = 0;
    let duration = 0;
    let animationFrame = null;
    let running = false;

    const clamp = (value, min, max) =>
        Math.min(max, Math.max(min, value));

    const applyStyle = (style = {}) => {
        const rootStyle =
            document.documentElement.style;

        if (style.ring) {
            if (style.ring.trackColor) {
                rootStyle.setProperty(
                    '--vex-progress-track',
                    style.ring.trackColor
                );
            }

            if (style.ring.progressColor) {
                rootStyle.setProperty(
                    '--vex-progress-value',
                    style.ring.progressColor
                );
            }

            if (style.ring.glowColor) {
                rootStyle.setProperty(
                    '--vex-progress-glow',
                    style.ring.glowColor
                );
            }

            if (
                Number.isFinite(style.ring.size)
                && style.ring.size > 0
            ) {
                rootStyle.setProperty(
                    '--ring-size',
                    `${style.ring.size}px`
                );
            }

            if (
                Number.isFinite(style.ring.strokeWidth)
                && style.ring.strokeWidth > 0
            ) {
                rootStyle.setProperty(
                    '--ring-stroke',
                    `${style.ring.strokeWidth}px`
                );
            }
        }

        if (style.bar) {
            if (
                Number.isFinite(style.bar.width)
                && style.bar.width > 0
            ) {
                rootStyle.setProperty(
                    '--bar-width',
                    `${style.bar.width}px`
                );
            }

            if (
                Number.isFinite(style.bar.height)
                && style.bar.height > 0
            ) {
                rootStyle.setProperty(
                    '--bar-height',
                    `${style.bar.height}px`
                );
            }
        }

        if (style.typography) {
            if (style.typography.primary) {
                rootStyle.setProperty(
                    '--vex-serif',
                    style.typography.primary
                );
            }

            if (style.typography.secondary) {
                rootStyle.setProperty(
                    '--vex-sans',
                    style.typography.secondary
                );
            }
        }
    };

    const setProgress = (ratio) => {
        const progress =
            clamp(ratio, 0, 1);

        const offset =
            RING_CIRCUMFERENCE
            * (1 - progress);

        ringValue.style.strokeDasharray =
            `${RING_CIRCUMFERENCE}`;

        ringValue.style.strokeDashoffset =
            `${offset}`;

        ringPercent.textContent =
            `${Math.floor(progress * 100)}%`;

        barValue.style.width =
            `${progress * 100}%`;
    };

    const stopAnimation = () => {
        running = false;

        if (animationFrame !== null) {
            cancelAnimationFrame(animationFrame);
            animationFrame = null;
        }
    };

    const hide = () => {
        stopAnimation();

        root.classList.remove('is-visible');
        root.setAttribute('aria-hidden', 'true');

        currentTaskId = null;
        startedAt = 0;
        duration = 0;

        setProgress(0);
    };

    const animate = (timestamp) => {
        if (!running) {
            return;
        }

        const elapsed =
            timestamp - startedAt;

        const ratio =
            duration > 0
                ? elapsed / duration
                : 1;

        setProgress(ratio);

        if (ratio >= 1) {
            running = false;
            animationFrame = null;

            return;
        }

        animationFrame =
            requestAnimationFrame(animate);
    };

    const start = (payload) => {
        stopAnimation();

        currentTaskId =
            typeof payload.taskId === 'string'
                ? payload.taskId
                : null;

        duration =
            Number.isFinite(payload.duration)
                ? Math.max(1, payload.duration)
                : 1;

        label.textContent =
            typeof payload.label === 'string'
                ? payload.label
                : 'Working...';

        cancelHint.hidden =
            payload.useControl !== true;

        applyStyle(payload.style);

        const layout =
            payload.layout === 'bar'
                ? 'bar'
                : 'ring';

        ringLayout.hidden =
            layout !== 'ring';

        barLayout.hidden =
            layout !== 'bar';

        setProgress(0);

        root.setAttribute(
            'aria-hidden',
            'false'
        );

        root.classList.add(
            'is-visible'
        );

        running = true;

        animationFrame =
            requestAnimationFrame(
                (timestamp) => {
                    startedAt = timestamp;
                    animate(timestamp);
                }
            );
    };

    const cancel = (payload) => {
        if (
            payload.taskId
            && currentTaskId
            && payload.taskId !== currentTaskId
        ) {
            return;
        }

        hide();
    };

    const complete = (payload) => {
        if (
            payload.taskId
            && currentTaskId
            && payload.taskId !== currentTaskId
        ) {
            return;
        }

        setProgress(1);

        window.setTimeout(
            hide,
            90
        );
    };

    window.addEventListener(
        'message',
        (event) => {
            const payload =
                event.data;

            if (
                !payload
                || typeof payload !== 'object'
                || typeof payload.action !== 'string'
            ) {
                return;
            }

            switch (payload.action) {
                case 'start':
                    start(payload);
                    break;

                case 'cancel':
                    cancel(payload);
                    break;

                case 'complete':
                    complete(payload);
                    break;

                default:
                    break;
            }
        }
    );

    hide();
})();