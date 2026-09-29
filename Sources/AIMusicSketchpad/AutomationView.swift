import SwiftUI

struct AutomationEditor: View {
    @ObservedObject var studio: StudioModel
    let track: TrackModel
    let parameter: AutomationParameter
    let beatWidth: Double
    @State private var selectedPointID: UUID?
    private var lane: AutomationLane { track.automation?.first { $0.parameter == parameter } ?? AutomationLane(parameter: parameter) }
    private var coordinateSpace: String { "automation-\(track.id)-\(parameter.rawValue)" }
    private var pixelsPerSecond: Double { beatWidth * studio.project.bpm / 60 }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var zero = Path()
                    zero.move(to: CGPoint(x: 0, y: size.height / 2))
                    zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(zero, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    var curve = Path()
                    curve.move(to: CGPoint(x: 0, y: y(lane.value(at: 0), height: size.height)))
                    for point in lane.points.sorted(by: { $0.seconds < $1.seconds }) {
                        curve.addLine(to: CGPoint(x: point.seconds * pixelsPerSecond, y: y(point.value, height: size.height)))
                    }
                    curve.addLine(to: CGPoint(x: size.width, y: y(lane.value(at: size.width / pixelsPerSecond), height: size.height)))
                    context.stroke(curve, with: .color(.orange), lineWidth: 2)
                }
                .background(Color.orange.opacity(0.035))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { event in
                    studio.setAutomationPoint(trackID: track.id, parameter: parameter,
                        seconds: event.location.x / pixelsPerSecond, value: value(event.location.y, height: geometry.size.height))
                })
                Text("0").font(.caption2).foregroundStyle(.secondary).offset(x: 3, y: geometry.size.height / 2 + 3).allowsHitTesting(false)
                ForEach(lane.points) { point in
                    Circle().fill(.orange).frame(width: 10, height: 10)
                        .padding(6).contentShape(Rectangle())
                        .position(x: point.seconds * pixelsPerSecond, y: y(point.value, height: geometry.size.height))
                        .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace)).onChanged { event in
                            selectedPointID = point.id
                            studio.setAutomationPoint(trackID: track.id, parameter: parameter, id: point.id,
                                seconds: event.location.x / pixelsPerSecond, value: value(event.location.y, height: geometry.size.height))
                        })
                        .contextMenu {
                            Button("Reset point to zero") { studio.setAutomationPoint(trackID: track.id, parameter: parameter, id: point.id, seconds: point.seconds, value: 0) }
                            Button("Delete point", role: .destructive) { studio.removeAutomationPoint(trackID: track.id, parameter: parameter, id: point.id) }
                        }
                        .help(String(format: "%.2f s • %@", point.seconds, parameter.label(point.value)))
                }
                if let point = lane.points.first(where: { $0.id == selectedPointID }) {
                    Text(String(format: "%@ • %.2f s • %@", parameter.rawValue, point.seconds, parameter.label(point.value)))
                        .font(.caption2.monospacedDigit()).padding(3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: max(2, point.seconds * pixelsPerSecond - 60), y: 2)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: coordinateSpace)
        }
        .frame(height: 100)
        .overlay(alignment: .bottom) { Divider() }
    }
    private func y(_ value: Double, height: Double) -> Double { height * (0.5 - value * 0.4) }
    private func value(_ y: Double, height: Double) -> Double { max(-1, min(1, (0.5 - y / height) / 0.4)) }
}
