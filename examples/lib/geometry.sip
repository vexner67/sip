# Модуль: импортируется из report.sip
import math

type Shape = Circle(r float) | Rect(w float, h float)

fn area(s Shape) float = match s
    Circle(r) -> math.pi * r * r
    Rect(w, h) -> w * h

fn total(shapes [Shape]) float = sum(area(s) for s in shapes)
