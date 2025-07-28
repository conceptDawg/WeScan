//
//  CaptureManager.swift
//  WeScan
//
//  Created by Boris Emorine on 2/8/18.
//  Copyright © 2018 WeTransfer. All rights reserved.
//

import AVFoundation
import CoreImage
import CoreMotion
import Foundation
import UIKit

/// Camera type options for lens selection
public enum CameraType: String, CaseIterable {
    case wide = "Wide"
    case ultraWide = "Ultra Wide" 
    case telephoto = "Telephoto"
    case auto = "Auto"
    
    @available(iOS 13.0, *)
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide:
            return .builtInWideAngleCamera
        case .ultraWide:
            return .builtInUltraWideCamera
        case .telephoto:
            if #available(iOS 15.4, *) {
                return .builtInTelephotoCamera
            } else {
                return .builtInWideAngleCamera
            }
        case .auto:
            return .builtInWideAngleCamera
        }
    }
    
    /// Returns the priority order for camera selection in auto mode
    static var autoPriorityOrder: [CameraType] {
        return [.wide, .ultraWide, .telephoto]
    }
}

/// Data structure containing information about the quadrilateral detected by CaptureSessionManager.
struct RectangleDetectorResult {
    let rectangle: Quadrilateral
    let imageSize: CGSize
}

/// Protocol used by CaptureSessionManager to communicate with its delegate.
protocol RectangleDetectionDelegateProtocol: NSObjectProtocol {
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didFailWithError error: Error)

    func didStartCapturingPicture(for captureSessionManager: CaptureSessionManager)
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didCapturePicture picture: UIImage, withQuad quad: Quadrilateral?)
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didDetectQuad quad: Quadrilateral?, _ imageSize: CGSize)
}

/// The CaptureSessionManager is responsible for setting up and managing the AVCaptureSession and the functions related to capturing.
final class CaptureSessionManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let captureSession = AVCaptureSession()
    private let rectangleFunnel = RectangleFeaturesFunnel()
    private let videoPreviewLayer: AVCaptureVideoPreviewLayer
    private let photoOutput = AVCapturePhotoOutput()
    
    weak var delegate: RectangleDetectionDelegateProtocol?
    private var displayedRectangleResult: RectangleDetectorResult?
    
    /// Rectangle detection configuration parameters
    private let minimumAspectRatio: Float
    private let maximumAspectRatio: Float
    private let minimumConfidence: Float
    private let maximumObservations: Int
    private let minimumSize: Float
    private let quadratureTolerance: Float
    
    /// Camera configuration
    private var preferredCameraType: CameraType
    private var macroModeEnabled: Bool
    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    
    /// Auto mode state tracking
    private var availableCameras: [CameraType: AVCaptureDevice] = [:]
    private var lastDetectionQuality: Float = 0.0
    private var detectionQualityHistory: [Float] = []
    private let detectionQualityWindowSize = 10

    /// Whether the CaptureSessionManager should be detecting quadrilaterals.
    private var isDetecting = true

    /// The number of times no rectangles have been found in a row.
    private var noRectangleCount = 0

    /// The minimum number of time required by `noRectangleCount` to validate that no rectangles have been found.
    private let noRectangleThreshold = 3

    // MARK: - Life Cycle

    init(videoPreviewLayer: AVCaptureVideoPreviewLayer, 
         delegate: RectangleDetectionDelegateProtocol,
         minimumAspectRatio: Float = 0.3,
         maximumAspectRatio: Float = 1.0,
         minimumConfidence: Float = 0.8,
         maximumObservations: Int = 1,
         minimumSize: Float = 0.2,
         quadratureTolerance: Float = 30.0,
         preferredCameraType: CameraType = .auto,
         macroModeEnabled: Bool = false) {
        self.videoPreviewLayer = videoPreviewLayer
        self.delegate = delegate
        self.minimumAspectRatio = minimumAspectRatio
        self.maximumAspectRatio = maximumAspectRatio
        self.minimumConfidence = minimumConfidence
        self.maximumObservations = maximumObservations
        self.minimumSize = minimumSize
        self.quadratureTolerance = quadratureTolerance
        self.preferredCameraType = preferredCameraType
        self.macroModeEnabled = macroModeEnabled
        super.init()
        
        captureSession.sessionPreset = AVCaptureSession.Preset.photo
        setupSession()
    }
    
    private func setupSession() {
        // Discover all available cameras first
        discoverAvailableCameras()
        
        let device = findBestCamera()
        guard let selectedDevice = device else {
            let error = ImageScannerControllerError.inputDevice
            delegate?.captureSessionManager(self, didFailWithError: error)
            return
        }
        
        currentDevice = selectedDevice
        
        captureSession.beginConfiguration()
        photoOutput.isHighResolutionCaptureEnabled = true

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true

        defer {
            selectedDevice.unlockForConfiguration()
            captureSession.commitConfiguration()
        }

        guard let deviceInput = try? AVCaptureDeviceInput(device: selectedDevice),
            captureSession.canAddInput(deviceInput),
            captureSession.canAddOutput(photoOutput),
            captureSession.canAddOutput(videoOutput) else {
                let error = ImageScannerControllerError.inputDevice
                delegate?.captureSessionManager(self, didFailWithError: error)
                return
        }
        
        currentInput = deviceInput

        do {
            try selectedDevice.lockForConfiguration()
        } catch {
            let error = ImageScannerControllerError.inputDevice
            delegate?.captureSessionManager(self, didFailWithError: error)
            return
        }

        selectedDevice.isSubjectAreaChangeMonitoringEnabled = true
        
        // Configure proper focus settings first
        configureFocusSettings(for: selectedDevice)
        
        // Then configure macro mode based on current camera and conditions
        configureMacroMode(for: selectedDevice)

        captureSession.addInput(deviceInput)
        captureSession.addOutput(photoOutput)
        captureSession.addOutput(videoOutput)

        let photoPreset = AVCaptureSession.Preset.photo

        if captureSession.canSetSessionPreset(photoPreset) {
            captureSession.sessionPreset = photoPreset

            if photoOutput.isLivePhotoCaptureSupported {
                photoOutput.isLivePhotoCaptureEnabled = true
            }
        }
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .background))
    }
    
    // MARK: - Camera Discovery and Selection
    
    private func discoverAvailableCameras() {
        availableCameras.removeAll()
        
        if #available(iOS 13.0, *) {
            let allDeviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera
            ]
            
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: allDeviceTypes,
                mediaType: .video,
                position: .back
            )
            
            for device in discoverySession.devices {
                switch device.deviceType {
                case .builtInWideAngleCamera:
                    availableCameras[.wide] = device
                case .builtInUltraWideCamera:
                    availableCameras[.ultraWide] = device
                case .builtInTelephotoCamera:
                    availableCameras[.telephoto] = device
                default:
                    break
                }
            }
        } else {
            // iOS 12 and earlier - only wide camera available
            if let device = AVCaptureDevice.default(for: .video) {
                availableCameras[.wide] = device
            }
        }
        
        print("📸 Available cameras: \(availableCameras.keys.map { $0.rawValue })")
    }
    
    private func findBestCamera() -> AVCaptureDevice? {
        if preferredCameraType == .auto {
            return findBestCameraForScanning()
        } else {
            return findSpecificCamera(type: preferredCameraType)
        }
    }
    
    private func findSpecificCamera(type: CameraType) -> AVCaptureDevice? {
        // First try to get the exact camera type requested
        if let device = availableCameras[type] {
            print("📸 Selected \(type.rawValue) camera")
            return device
        }
        
        // Fallback to wide camera if specific type not available
        if let wideCamera = availableCameras[.wide] {
            print("📸 Fallback to Wide camera (requested \(type.rawValue) not available)")
            return wideCamera
        }
        
        // Last resort - use default system camera
        return AVCaptureDevice.default(for: .video)
    }
    
    private func findBestCameraForScanning() -> AVCaptureDevice? {
        // Intelligent camera selection based on scanning conditions
        
        // Priority 1: Wide camera for general scanning (most reliable)
        if let wideCamera = availableCameras[.wide] {
            // Check if this is a good camera for scanning
            if evaluateCameraForScanning(wideCamera) >= 0.7 {
                print("📸 Auto-selected Wide camera (optimal for scanning)")
                return wideCamera
            }
        }
        
        // Priority 2: Ultra-wide for larger documents or when close to subject
        if let ultraWideCamera = availableCameras[.ultraWide] {
            if evaluateCameraForScanning(ultraWideCamera) >= 0.6 {
                print("📸 Auto-selected Ultra Wide camera (better field of view)")
                return ultraWideCamera
            }
        }
        
        // Priority 3: Telephoto for distant or detailed scanning
        if let telephotoCamera = availableCameras[.telephoto] {
            if evaluateCameraForScanning(telephotoCamera) >= 0.5 {
                print("📸 Auto-selected Telephoto camera (better for detail)")
                return telephotoCamera
            }
        }
        
        // Fallback: Use first available camera in priority order
        for cameraType in CameraType.autoPriorityOrder {
            if let camera = availableCameras[cameraType] {
                print("📸 Auto-selected \(cameraType.rawValue) camera (fallback)")
                return camera
            }
        }
        
        // Last resort
        return AVCaptureDevice.default(for: .video)
    }
    
    private func evaluateCameraForScanning(_ device: AVCaptureDevice) -> Float {
        var score: Float = 0.5 // Base score
        
        // Prefer cameras with better autofocus capabilities
        if device.isFocusModeSupported(.continuousAutoFocus) {
            score += 0.2
        }
        
        // Prefer cameras with good macro capabilities
        if #available(iOS 15.0, *) {
            if device.isAutoFocusRangeRestrictionSupported {
                score += 0.1
            }
        }
        
        // Prefer cameras with image stabilization
        if device.activeFormat.isVideoStabilizationModeSupported(.auto) {
            score += 0.1
        }
        
        // Consider field of view (ultra-wide might be better for large documents)
        switch device.deviceType {
        case .builtInWideAngleCamera:
            score += 0.1 // Standard good choice
        case .builtInUltraWideCamera:
            score += 0.05 // Good for large documents but may have distortion
        case .builtInTelephotoCamera:
            score += 0.05 // Good for detailed work but limited field of view
        default:
            break
        }
        
        return min(score, 1.0)
    }
    
    private func shouldEnableMacroMode(for device: AVCaptureDevice) -> Bool {
        // If macro mode was explicitly requested, honor that
        if macroModeEnabled {
            return true
        }
        
        // Auto-detect if macro mode would be beneficial
        // This could be based on detection history, document size, etc.
        let averageDetectionQuality = detectionQualityHistory.isEmpty ? 0.0 : 
            detectionQualityHistory.reduce(0, +) / Float(detectionQualityHistory.count)
        
        // Enable macro if detection quality is poor (might be too close)
        if averageDetectionQuality < 0.3 {
            print("📸 Auto-enabling macro mode due to poor detection quality")
            return true
        }
        
        // Enable macro for telephoto camera by default (good for detailed work)
        if device.deviceType == .builtInTelephotoCamera {
            print("📸 Auto-enabling macro mode for telephoto camera")
            return true
        }
        
        return false
    }
    
    private func configureMacroMode(for device: AVCaptureDevice) {
        let shouldUseMacro = shouldEnableMacroMode(for: device)
        
        guard shouldUseMacro else { 
            // Normal mode - reset focus range restriction if it was set
            if #available(iOS 15.0, *) {
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = .none
                }
            }
            return
        }
        
        print("📸 Configuring macro mode for \(device.localizedName)")
        
        // For macro mode, optimize the focus range but don't change focus mode
        // (focus mode is already set by configureFocusSettings)
        if #available(iOS 15.0, *) {
            // Enable auto focus range restriction for near subjects
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            
            // Only set custom lens position if we're in a locked focus mode scenario
            // For most cases, let the continuous autofocus handle it with near restriction
        }
    }
    
    // MARK: - Camera Switching
    
    func switchCamera(to newType: CameraType) {
        guard newType != preferredCameraType else { return }
        
        print("📸 Switching camera from \(preferredCameraType.rawValue) to \(newType.rawValue)")
        
        // Stop the session before making changes
        let wasRunning = captureSession.isRunning
        if wasRunning {
            captureSession.stopRunning()
        }
        
        captureSession.beginConfiguration()
        
        // Remove current input
        if let currentInput = currentInput {
            captureSession.removeInput(currentInput)
        }
        
        // Update preferred camera type
        preferredCameraType = newType
        
        // Find new camera
        let newDevice = findBestCamera()
        
        guard let device = newDevice,
              let newInput = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(newInput) else {
            // Restore previous input if switching fails
            if let currentInput = currentInput {
                captureSession.addInput(currentInput)
            }
            captureSession.commitConfiguration()
            
            // Restart session if it was running
            if wasRunning {
                captureSession.startRunning()
            }
            
            print("❌ Failed to switch camera")
            return
        }
        
        // Configure new device
        do {
            try device.lockForConfiguration()
            device.isSubjectAreaChangeMonitoringEnabled = true
            
            // Configure proper focus settings
            configureFocusSettings(for: device)
            
            // Configure macro mode
            configureMacroMode(for: device)
            
            device.unlockForConfiguration()
        } catch {
            print("Failed to configure new camera device: \(error)")
        }
        
        // Add new input
        captureSession.addInput(newInput)
        
        // Update references
        currentDevice = device
        currentInput = newInput
        
        captureSession.commitConfiguration()
        
        // Update preview layer on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.videoPreviewLayer.session = self.captureSession
            self.videoPreviewLayer.videoGravity = .resizeAspectFill
            
            // Restart session if it was running
            if wasRunning {
                self.captureSession.startRunning()
            }
        }
        
        // Reset detection quality history when switching cameras
        detectionQualityHistory.removeAll()
        
        print("✅ Successfully switched to \(newType.rawValue) camera")
    }
    
    private func configureFocusSettings(for device: AVCaptureDevice) {
        // Set up proper autofocus mode
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        } else if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }
        
        // Set up exposure mode
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        
        // Enable smooth autofocus if available
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        
        print("📸 Configured focus settings for \(device.localizedName)")
    }
    
    // MARK: - Focus Control
    
    /// Sets the camera's focus point to the given tap point
    func setFocusPointToTapPoint(_ tapPoint: CGPoint) {
        guard let device = currentDevice else {
            print("❌ No current device for focus")
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            defer {
                device.unlockForConfiguration()
            }
            
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = tapPoint
                device.focusMode = .autoFocus
                print("📸 Focus point set to \(tapPoint)")
            }
            
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = tapPoint
                device.exposureMode = .continuousAutoExposure
            }
            
        } catch {
            print("❌ Failed to set focus point: \(error)")
        }
    }
    
    /// Resets the camera's focus to automatic mode
    func resetFocusToAuto() {
        guard let device = currentDevice else {
            print("❌ No current device for focus reset")
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            defer {
                device.unlockForConfiguration()
            }
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            print("📸 Focus reset to auto")
            
        } catch {
            print("❌ Failed to reset focus: \(error)")
        }
    }
    
    // MARK: - Auto-optimization based on detection quality
    
    func updateDetectionQuality(_ quality: Float) {
        lastDetectionQuality = quality
        detectionQualityHistory.append(quality)
        
        // Keep history window manageable
        if detectionQualityHistory.count > detectionQualityWindowSize {
            detectionQualityHistory.removeFirst()
        }
        
        // Only auto-switch if we're in auto mode
        guard preferredCameraType == .auto else { return }
        
        // Calculate average quality over recent history
        let averageQuality = detectionQualityHistory.reduce(0, +) / Float(detectionQualityHistory.count)
        
        // If quality is consistently poor, try switching cameras
        if detectionQualityHistory.count >= detectionQualityWindowSize && averageQuality < 0.3 {
            considerCameraSwitch()
        }
    }
    
    private func considerCameraSwitch() {
        guard let currentDevice = currentDevice else { return }
        
        // Don't switch too frequently
        let lastSwitchKey = "lastCameraSwitchTime"
        let now = Date().timeIntervalSince1970
        let lastSwitch = UserDefaults.standard.double(forKey: lastSwitchKey)
        
        if now - lastSwitch < 10.0 { // Don't switch more than once every 10 seconds
            return
        }
        
        print("📸 Poor detection quality (\(String(format: "%.2f", lastDetectionQuality))), considering camera switch")
        
        // Try next camera in priority order
        let currentType = getCameraType(for: currentDevice)
        let priorityOrder = CameraType.autoPriorityOrder
        
        if let currentIndex = priorityOrder.firstIndex(of: currentType) {
            let nextIndex = (currentIndex + 1) % priorityOrder.count
            let nextType = priorityOrder[nextIndex]
            
            if availableCameras[nextType] != nil {
                print("📸 Auto-switching to \(nextType.rawValue) for better detection")
                switchCamera(to: nextType)
                UserDefaults.standard.set(now, forKey: lastSwitchKey)
            }
        }
    }
    
    private func getCameraType(for device: AVCaptureDevice) -> CameraType {
        for (type, typeDevice) in availableCameras {
            if typeDevice == device {
                return type
            }
        }
        return .wide // Default fallback
    }
    
    // MARK: - Public API
    
    /// Get currently available camera types
    var availableCameraTypes: [CameraType] {
        return Array(availableCameras.keys).sorted { $0.rawValue < $1.rawValue }
    }
    
    /// Get current camera type
    var currentCameraType: CameraType {
        guard let currentDevice = currentDevice else { return .wide }
        return getCameraType(for: currentDevice)
    }
    
    /// Toggle macro mode on/off
    func toggleMacroMode() {
        macroModeEnabled.toggle()
        
        guard let device = currentDevice else { return }
        
        do {
            try device.lockForConfiguration()
            configureMacroMode(for: device)
            device.unlockForConfiguration()
            print("📸 Macro mode \(macroModeEnabled ? "enabled" : "disabled")")
        } catch {
            print("Failed to toggle macro mode: \(error)")
        }
    }

    // MARK: Capture Session Life Cycle

    /// Starts the camera and detecting quadrilaterals.
    internal func start() {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch authorizationStatus {
        case .authorized:
            DispatchQueue.main.async {
                self.captureSession.startRunning()
            }
            isDetecting = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: AVMediaType.video, completionHandler: { _ in
                DispatchQueue.main.async { [weak self] in
                    self?.start()
                }
            })
        default:
            let error = ImageScannerControllerError.authorization
            delegate?.captureSessionManager(self, didFailWithError: error)
        }
    }

    internal func stop() {
        captureSession.stopRunning()
    }

    internal func capturePhoto() {
        guard let connection = photoOutput.connection(with: .video), connection.isEnabled, connection.isActive else {
            let error = ImageScannerControllerError.capture
            delegate?.captureSessionManager(self, didFailWithError: error)
            return
        }
        CaptureSession.current.setImageOrientation()
        let photoSettings = AVCapturePhotoSettings()
        photoSettings.isHighResolutionPhotoEnabled = true
        photoSettings.isAutoStillImageStabilizationEnabled = true
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isDetecting == true,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        if #available(iOS 11.0, *) {
            VisionRectangleDetector.rectangle(
                forPixelBuffer: pixelBuffer,
                minimumAspectRatio: minimumAspectRatio,
                maximumAspectRatio: maximumAspectRatio,
                minimumConfidence: minimumConfidence,
                maximumObservations: maximumObservations,
                minimumSize: minimumSize,
                quadratureTolerance: quadratureTolerance
            ) { rectangle in
                self.processRectangle(rectangle: rectangle, imageSize: imageSize)
            }
        } else {
            let finalImage = CIImage(cvPixelBuffer: pixelBuffer)
            CIRectangleDetector.rectangle(forImage: finalImage) { rectangle in
                self.processRectangle(rectangle: rectangle, imageSize: imageSize)
            }
        }
    }

    private func processRectangle(rectangle: Quadrilateral?, imageSize: CGSize) {
        if let rectangle {
            
            // Update detection quality for auto-optimization
            let quality = calculateDetectionQuality(rectangle: rectangle, imageSize: imageSize)
            updateDetectionQuality(quality)

            self.noRectangleCount = 0
            self.rectangleFunnel
                .add(rectangle, currentlyDisplayedRectangle: self.displayedRectangleResult?.rectangle) { [weak self] result, rectangle in

                guard let self else {
                    return
                }

                let shouldAutoScan = (result == .showAndAutoScan)
                self.displayRectangleResult(rectangleResult: RectangleDetectorResult(rectangle: rectangle, imageSize: imageSize))
                if shouldAutoScan, CaptureSession.current.isAutoScanEnabled, !CaptureSession.current.isEditing {
                    capturePhoto()
                }
            }

        } else {
            // Update detection quality for failed detections
            updateDetectionQuality(0.0)

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.noRectangleCount += 1

                if self.noRectangleCount > self.noRectangleThreshold {
                    // Reset the currentAutoScanPassCount, so the threshold is restarted the next time a rectangle is found
                    self.rectangleFunnel.currentAutoScanPassCount = 0

                    // Remove the currently displayed rectangle as no rectangles are being found anymore
                    self.displayedRectangleResult = nil
                    self.delegate?.captureSessionManager(self, didDetectQuad: nil, imageSize)
                }
            }
            return

        }
    }
    
    private func calculateDetectionQuality(rectangle: Quadrilateral, imageSize: CGSize) -> Float {
        // Calculate a quality score based on rectangle properties
        let boundingBox = calculateBoundingBox(for: rectangle)
        let area = boundingBox.width * boundingBox.height
        let relativeArea = area / (imageSize.width * imageSize.height)
        
        // Prefer rectangles that are a reasonable size (not too small or too large)
        let optimalAreaRange: ClosedRange<CGFloat> = 0.1...0.8
        let areaScore = optimalAreaRange.contains(relativeArea) ? 1.0 : 0.5
        
        // Calculate aspect ratio quality
        let aspectRatio = boundingBox.width / boundingBox.height
        let aspectScore: Float
        
        // Prefer aspect ratios within our detection parameters
        if aspectRatio >= CGFloat(minimumAspectRatio) && aspectRatio <= CGFloat(maximumAspectRatio) {
            aspectScore = 1.0
        } else {
            aspectScore = 0.3
        }
        
        // Calculate rectangle regularity (how close to a proper rectangle)
        let regularityScore = calculateRectangleRegularity(rectangle)
        
        // Combine scores
        let quality = Float(areaScore) * aspectScore * regularityScore
        return min(quality, 1.0)
    }
    
    private func calculateBoundingBox(for rectangle: Quadrilateral) -> CGRect {
        let points = [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
        
        let minX = points.map { $0.x }.min() ?? 0
        let maxX = points.map { $0.x }.max() ?? 0
        let minY = points.map { $0.y }.min() ?? 0
        let maxY = points.map { $0.y }.max() ?? 0
        
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    private func calculateRectangleRegularity(_ rectangle: Quadrilateral) -> Float {
        // Check how close the quadrilateral is to a proper rectangle
        let points = [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
        
        // Calculate angles - a perfect rectangle should have 90-degree angles
        var angleScore: Float = 1.0
        for i in 0..<4 {
            let p1 = points[i]
            let p2 = points[(i + 1) % 4]
            let p3 = points[(i + 2) % 4]
            
            let angle = calculateAngle(p1: p1, vertex: p2, p2: p3)
            let deviationFromRight = abs(angle - 90.0)
            
            // Penalize large deviations from 90 degrees
            if deviationFromRight > CGFloat(quadratureTolerance) {
                angleScore *= 0.7
            }
        }
        
        return angleScore
    }
    
    private func calculateAngle(p1: CGPoint, vertex: CGPoint, p2: CGPoint) -> CGFloat {
        let v1 = CGVector(dx: p1.x - vertex.x, dy: p1.y - vertex.y)
        let v2 = CGVector(dx: p2.x - vertex.x, dy: p2.y - vertex.y)
        
        let dot = v1.dx * v2.dx + v1.dy * v2.dy
        let det = v1.dx * v2.dy - v1.dy * v2.dx
        
        let angle = atan2(det, dot) * 180.0 / .pi
        return abs(angle)
    }

    @discardableResult private func displayRectangleResult(rectangleResult: RectangleDetectorResult) -> Quadrilateral {
        displayedRectangleResult = rectangleResult

        let quad = rectangleResult.rectangle.toCartesian(withHeight: rectangleResult.imageSize.height)

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.delegate?.captureSessionManager(self, didDetectQuad: quad, rectangleResult.imageSize)
        }

        return quad
    }

}

extension CaptureSessionManager: AVCapturePhotoCaptureDelegate {

    // swiftlint:disable function_parameter_count
    func photoOutput(_ captureOutput: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?,
                     previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?,
                     resolvedSettings: AVCaptureResolvedPhotoSettings,
                     bracketSettings: AVCaptureBracketedStillImageSettings?,
                     error: Error?
    ) {
        if let error {
            delegate?.captureSessionManager(self, didFailWithError: error)
            return
        }

        isDetecting = false
        rectangleFunnel.currentAutoScanPassCount = 0
        delegate?.didStartCapturingPicture(for: self)

        if let sampleBuffer = photoSampleBuffer,
            let imageData = AVCapturePhotoOutput.jpegPhotoDataRepresentation(
                forJPEGSampleBuffer: sampleBuffer,
                previewPhotoSampleBuffer: nil
            ) {
            completeImageCapture(with: imageData)
        } else {
            let error = ImageScannerControllerError.capture
            delegate?.captureSessionManager(self, didFailWithError: error)
            return
        }

    }

    @available(iOS 11.0, *)
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            delegate?.captureSessionManager(self, didFailWithError: error)
            return
        }

        isDetecting = false
        rectangleFunnel.currentAutoScanPassCount = 0
        delegate?.didStartCapturingPicture(for: self)

        if let imageData = photo.fileDataRepresentation() {
            completeImageCapture(with: imageData)
        } else {
            let error = ImageScannerControllerError.capture
            delegate?.captureSessionManager(self, didFailWithError: error)
            return
        }
    }

    /// Completes the image capture by processing the image, and passing it to the delegate object.
    /// This function is necessary because the capture functions for iOS 10 and 11 are decoupled.
    private func completeImageCapture(with imageData: Data) {
        DispatchQueue.global(qos: .background).async { [weak self] in
            CaptureSession.current.isEditing = true
            guard let image = UIImage(data: imageData) else {
                let error = ImageScannerControllerError.capture
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.delegate?.captureSessionManager(self, didFailWithError: error)
                }
                return
            }

            var angle: CGFloat = 0.0

            switch image.imageOrientation {
            case .right:
                angle = CGFloat.pi / 2
            case .up:
                angle = CGFloat.pi
            default:
                break
            }

            var quad: Quadrilateral?
            if let displayedRectangleResult = self?.displayedRectangleResult {
                quad = self?.displayRectangleResult(rectangleResult: displayedRectangleResult)
                quad = quad?.scale(displayedRectangleResult.imageSize, image.size, withRotationAngle: angle)
            }

            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.delegate?.captureSessionManager(self, didCapturePicture: image, withQuad: quad)
            }
        }
    }
}
