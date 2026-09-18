import { Controller } from "@hotwired/stimulus";

// Manual intra-day ordering for the flat compact activity view. Each day is
// its own controller scope, so drags can never cross into another date.
// Valuations render without a unit target and stay pinned; the drop math
// only considers units, which keeps drops below them automatically.
//
// Display order is top-to-bottom (reverse chronological); the server stores
// walk order, so the client submits DOM order and the server reverses it.
export default class extends Controller {
  static targets = ["unit"];
  static values = {
    url: String,
    date: String,
    grouped: Boolean,
  };

  connect() {
    this.draggedUnit = null;
    this.initialOrder = null;
  }

  disconnect() {
    this.draggedUnit = null;
    this.initialOrder = null;
  }

  dragUnit(event) {
    const unit = event.currentTarget.closest('[data-activity-reorder-target="unit"]');
    if (!unit) return;

    this.draggedUnit = unit;
    this.initialOrder = this.orderedKeys();
    event.dataTransfer.effectAllowed = "move";
    // setData is required for Firefox to start the drag.
    event.dataTransfer.setData("text/plain", unit.dataset.reorderKey);
    unit.classList.add("opacity-50");
  }

  releaseUnit() {
    this.draggedUnit?.classList.remove("opacity-50");
    this.draggedUnit = null;
  }

  dragOver(event) {
    if (!this.draggedUnit) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";

    const afterElement = this.getDragAfterElement(event.clientY);
    if (afterElement == null) {
      this.element.appendChild(this.draggedUnit);
    } else if (afterElement !== this.draggedUnit) {
      this.element.insertBefore(this.draggedUnit, afterElement);
    }
  }

  async dropUnit(event) {
    if (!this.draggedUnit) return;
    event.preventDefault();

    const unit = this.draggedUnit;
    unit.classList.remove("opacity-50");
    this.draggedUnit = null;

    const keys = this.orderedKeys();
    if (this.sameOrder(keys, this.initialOrder)) return;

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "text/vnd.turbo-stream.html",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
        },
        body: JSON.stringify({
          date: this.dateValue,
          entry_ids: keys,
          grouped: this.groupedValue,
        }),
      });

      if (response.ok) {
        Turbo.renderStreamMessage(await response.text());
      } else {
        // Order on screen may no longer match the server — reload to a
        // consistent state rather than leave a misleading arrangement.
        window.location.reload();
      }
    } catch (error) {
      console.error("[activity-reorder] persist failed", error);
      window.location.reload();
    }
  }

  orderedKeys() {
    return this.unitTargets.map((unit) => unit.dataset.reorderKey);
  }

  sameOrder(keys, other) {
    if (!other || keys.length !== other.length) return false;
    return keys.every((key, index) => key === other[index]);
  }

  getDragAfterElement(y) {
    return this.unitTargets
      .filter((unit) => unit !== this.draggedUnit)
      .reduce(
        (closest, unit) => {
          const box = unit.getBoundingClientRect();
          const offset = y - box.top - box.height / 2;
          if (offset < 0 && offset > closest.offset) {
            return { offset, element: unit };
          }
          return closest;
        },
        { offset: Number.NEGATIVE_INFINITY, element: null },
      ).element;
  }
}
