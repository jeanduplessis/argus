import { FileDiff } from "@pierre/diffs";

const bridgeName = "argusDiffBridge";
const state = {
  input: null,
  renderer: null,
  theme: "dark",
  style: "split",
  overflow: "scroll",
};

function post(type, message) {
  window.webkit?.messageHandlers?.[bridgeName]?.postMessage({ type, message });
}

function decodeInput(encodedInput) {
  const bytes = Uint8Array.from(atob(encodedInput), (character) => character.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}

function file(input) {
  const value = {
    name: input.name,
    contents: input.contents,
  };
  if (input.language) value.lang = input.language;
  return value;
}

function rendererOptions() {
  return {
    themeType: state.theme,
    diffStyle: state.style,
    overflow: state.overflow,
    stickyHeader: true,
  };
}

function render(encodedInput) {
  try {
    state.input = decodeInput(encodedInput);
    state.theme = state.input.options.theme;
    state.style = state.input.options.style;
    state.overflow = state.input.options.overflow;
    state.renderer?.cleanUp();
    document.getElementById("diff").replaceChildren();
    state.renderer = new FileDiff(rendererOptions());
    state.renderer.render({
      oldFile: file(state.input.oldFile),
      newFile: file(state.input.newFile),
      containerWrapper: document.getElementById("diff"),
    });
  } catch (error) {
    post("error", error instanceof Error ? error.message : String(error));
  }
}

function updateOptions(options) {
  if (!state.renderer) return;
  state.renderer.setOptions({ ...state.renderer.options, ...options });
  state.renderer.rerender();
}

function setTheme(theme) {
  state.theme = theme;
  state.renderer?.setThemeType(theme);
}

function setStyle(style) {
  state.style = style;
  updateOptions({ diffStyle: style });
}

function setOverflow(overflow) {
  state.overflow = overflow;
  updateOptions({ overflow });
}

function cleanup() {
  state.renderer?.cleanUp();
  state.renderer = null;
  state.input = null;
  document.getElementById("diff")?.replaceChildren();
}

window.argusDiff = { render, setTheme, setStyle, setOverflow, cleanup };
post("ready", "Pierre diff renderer ready");
