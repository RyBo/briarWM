import Foundation
@testable import briarWM

func approx(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.5) -> Bool { abs(a - b) <= eps }

func rectApprox(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 0.5) -> Bool {
    approx(a.minX, b.minX, eps) && approx(a.minY, b.minY, eps) &&
    approx(a.width, b.width, eps) && approx(a.height, b.height, eps)
}
