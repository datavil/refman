import { expect, test } from "vitest";
import { setupPairingCode } from "../src/shared/pairing-code";

function makeControl(): { container: HTMLElement; inputs: HTMLInputElement[] } {
  document.body.innerHTML = `<div id="code">${Array.from(
    { length: 6 },
    () => '<input class="pair-code-digit">'
  ).join("")}</div>`;
  const container = document.getElementById("code")!;
  return {
    container,
    inputs: [...container.querySelectorAll<HTMLInputElement>("input")]
  };
}

test("accepts digits and removes non-numeric input", () => {
  const { container, inputs } = makeControl();
  const control = setupPairingCode(container);
  inputs[0].value = "a7";
  inputs[0].dispatchEvent(new InputEvent("input", { bubbles: true }));
  expect(inputs[0].value).toBe("7");
  expect(document.activeElement).toBe(inputs[1]);
  expect(control.value()).toBe("7");
});

test("distributes a pasted code across all six boxes", () => {
  const { container, inputs } = makeControl();
  const control = setupPairingCode(container);
  const event = new Event("paste", { bubbles: true, cancelable: true }) as ClipboardEvent;
  Object.defineProperty(event, "clipboardData", {
    value: { getData: () => "code: 743000" }
  });
  container.dispatchEvent(event);
  expect(inputs.map((input) => input.value)).toEqual(["7", "4", "3", "0", "0", "0"]);
  expect(control.value()).toBe("743000");
});
