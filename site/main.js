// Copy buttons, and a still trail for Reduce Motion. The page works without this script.

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
