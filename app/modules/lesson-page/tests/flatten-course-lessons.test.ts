import { describe, it, expect } from "vitest";
import { flattenCourseLessons } from "../course.server";

describe("flattenCourseLessons", () => {
  it("lists every lesson in module order, tagged with its module", () => {
    const flat = flattenCourseLessons({
      modules: [
        {
          id: 1,
          title: "Basics",
          lessons: [
            { id: 10, title: "Intro", moduleId: 1 },
            { id: 11, title: "Setup", moduleId: 1 },
          ],
        },
        { id: 2, title: "Empty", lessons: [] },
        {
          id: 3,
          title: "Generics",
          lessons: [{ id: 30, title: "Why", moduleId: 3 }],
        },
      ],
    });

    expect(flat).toEqual([
      { id: 10, title: "Intro", moduleId: 1, moduleTitle: "Basics" },
      { id: 11, title: "Setup", moduleId: 1, moduleTitle: "Basics" },
      { id: 30, title: "Why", moduleId: 3, moduleTitle: "Generics" },
    ]);
  });

  it("returns nothing for a course without modules", () => {
    expect(flattenCourseLessons({ modules: [] })).toEqual([]);
  });
});
