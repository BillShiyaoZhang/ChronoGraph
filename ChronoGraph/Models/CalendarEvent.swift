//
//  CalendarEvent.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import Foundation
import EventKit
import UIKit
import SwiftUI // 新增: 用于颜色表示

struct CalendarEvent: Identifiable, Hashable {
    // 将嵌套类型提前声明，避免某些解析器前向引用潜在问题
    enum Availability: String, CaseIterable, Hashable {
        case busy, free, tentative, unavailable, notSupported
        init(ekEventAvailability: EKEventAvailability) {
            switch ekEventAvailability {
            case .busy: self = .busy
            case .free: self = .free
            case .tentative: self = .tentative
            case .unavailable: self = .unavailable
            default: self = .notSupported
            }
        }
        var localizedName: String {
            switch self {
            case .busy: return NSLocalizedString("availability.busy", comment: "Busy")
            case .free: return NSLocalizedString("availability.free", comment: "Free")
            case .tentative: return NSLocalizedString("availability.tentative", comment: "Tentative")
            case .unavailable: return NSLocalizedString("availability.unavailable", comment: "Unavailable")
            case .notSupported: return NSLocalizedString("availability.unknown", comment: "Unknown")
            }
        }
        var color: Color {
            switch self {
            case .busy: return .red
            case .free: return .green
            case .tentative: return .orange
            case .unavailable: return .gray
            case .notSupported: return .secondary
            }
        }
    }
    
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let calendar: String
    let calendarColor: CGColor
    let isAllDay: Bool
    let availability: Availability // 新增：忙碌状态
    
    init(from ekEvent: EKEvent) {
        self.id = ekEvent.eventIdentifier
        self.title = ekEvent.title ?? NSLocalizedString("event.untitled", comment: "No Title")
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.location = ekEvent.location
        self.notes = ekEvent.notes
        self.calendar = ekEvent.calendar.title
        self.calendarColor = ekEvent.calendar.cgColor
        self.isAllDay = ekEvent.isAllDay
        self.availability = Availability(ekEventAvailability: ekEvent.availability)
    }
    
    // 便于预览/单元测试的便捷初始化
    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        calendar: String,
        calendarColor: CGColor = UIColor.systemBlue.cgColor,
        isAllDay: Bool = false,
        availability: Availability = .busy
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
        self.calendar = calendar
        self.calendarColor = calendarColor
        self.isAllDay = isAllDay
        self.availability = availability
    }
}

enum PrivacyMode: String, CaseIterable {
    case opaque = "opaque"
    case partial = "partial"
    case full = "full"

    static func migrateLegacy(raw: String) -> PrivacyMode? {
        switch raw {
        case "隐藏": return .opaque
        case "缩略": return .partial
        case "完整": return .full
        default: return nil
        }
    }
    
    var localizedName: String {
        switch self {
            case .opaque: return NSLocalizedString("privacy.opaque", comment: "Hidden")
            case .partial: return NSLocalizedString("privacy.partial", comment: "Partial")
            case .full: return NSLocalizedString("privacy.full", comment: "Full")
        }
    }
    
    // 提供 SwiftUI 环境感知的本地化 key
    var localizedKey: LocalizedStringKey {
        switch self {
        case .opaque: return LocalizedStringKey("privacy.opaque")
        case .partial: return LocalizedStringKey("privacy.partial")
        case .full: return LocalizedStringKey("privacy.full")
        }
    }
    
    var description: String {
        switch self {
        case .opaque: return NSLocalizedString("privacy.opaque.desc", comment: "Show only time blocks, hide details")
        case .partial: return NSLocalizedString("privacy.partial.desc", comment: "Show title and time")
        case .full: return NSLocalizedString("privacy.full.desc", comment: "Show all details")
        }
    }
    
    var systemImage: String {
        switch self {
        case .opaque: return "eye.slash"
        case .partial: return "eye.trianglebadge.exclamationmark"
        case .full: return "eye"
        }
    }
}
