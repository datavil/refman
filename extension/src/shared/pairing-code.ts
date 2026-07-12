export interface PairingCodeControl {
  value(): string;
}

export function setupPairingCode(container: HTMLElement): PairingCodeControl {
  const inputs = [...container.querySelectorAll<HTMLInputElement>(".pair-code-digit")];

  inputs.forEach((input, index) => {
    input.addEventListener("input", () => {
      input.value = input.value.replace(/\D/g, "").slice(-1);
      if (input.value && index < inputs.length - 1) inputs[index + 1].focus();
    });

    input.addEventListener("keydown", (event) => {
      if (event.key === "Backspace" && !input.value && index > 0) {
        inputs[index - 1].focus();
        inputs[index - 1].value = "";
      } else if (event.key === "ArrowLeft" && index > 0) {
        event.preventDefault();
        inputs[index - 1].focus();
      } else if (event.key === "ArrowRight" && index < inputs.length - 1) {
        event.preventDefault();
        inputs[index + 1].focus();
      }
    });
  });

  container.addEventListener("paste", (event) => {
    const digits = event.clipboardData?.getData("text").replace(/\D/g, "").slice(0, 6) ?? "";
    if (!digits) return;
    event.preventDefault();
    inputs.forEach((input, index) => { input.value = digits[index] ?? ""; });
    inputs[Math.min(digits.length, inputs.length) - 1]?.focus();
  });

  return {
    value: () => inputs.map((input) => input.value).join("")
  };
}
