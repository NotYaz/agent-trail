// Copy buttons, a still trail for Reduce Motion, and the theme picker. The page works without this script.

document.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-copy-target]");
  if (!button) return;
  const source = document.getElementById(button.dataset.copyTarget);
  if (!source) return;
  try {
    await navigator.clipboard.writeText(source.textContent.trim());
  } catch {
    return;
  }
  const label = button.getAttribute("aria-label");
  const icon = button.querySelector("use");
  button.classList.add("is-done");
  button.setAttribute("aria-label", "Copied");
  icon?.setAttribute("href", "#i-check");
  setTimeout(() => {
    button.classList.remove("is-done");
    button.setAttribute("aria-label", label);
    icon?.setAttribute("href", "#i-copy");
  }, 1600);
});

// SMIL ignores prefers-reduced-motion, so hold the travelling dot still.
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
function applyMotionPreference() {
  for (const runner of document.querySelectorAll(".runner")) {
    const svg = runner.ownerSVGElement;
    if (reduceMotion.matches) {
      svg.pauseAnimations();
      svg.setCurrentTime(0);
    } else {
      svg.unpauseAnimations();
    }
  }
}
applyMotionPreference();
reduceMotion.addEventListener("change", applyMotionPreference);

// Color themes, matching the app's ⋯ › Theme menu. Classic is the page's base,
// so it needs no attribute; screenshots switch to that theme's renders.
const themeKey = "agent-trail-theme";
const picker = document.querySelector(".theme-picker");
function applyTheme(theme) {
  if (theme === "classic") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = theme;
  for (const button of picker.querySelectorAll("[data-theme-choice]")) {
    button.setAttribute("aria-pressed", String(button.dataset.themeChoice === theme));
  }
  const suffix = theme === "classic" ? "" : `-${theme}`;
  for (const picture of document.querySelectorAll("picture[data-shot]")) {
    const shot = picture.dataset.shot;
    picture.querySelector("source").srcset = `assets/${shot}${suffix}-dark.webp`;
    picture.querySelector("img").src = `assets/${shot}${suffix}-light.webp`;
  }
}
if (picker) {
  picker.hidden = false;
  const saved = document.documentElement.dataset.theme;
  if (saved) applyTheme(saved);
  picker.addEventListener("click", (event) => {
    const button = event.target.closest("[data-theme-choice]");
    if (!button) return;
    const theme = button.dataset.themeChoice;
    applyTheme(theme);
    try {
      localStorage.setItem(themeKey, theme);
    } catch {}
  });
}
