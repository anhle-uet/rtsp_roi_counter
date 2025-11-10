#!/usr/bin/env python3
"""
RTSP Object Detection with ROI-based Counting
Counts persons and vehicles within defined ROI areas
Designed for headless Raspberry Pi 5 + Hailo-8 deployment
"""

import gi
gi.require_version('Gst', '1.0')
from gi.repository import Gst, GLib
import sys
import os
import json
import time
import signal
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import List, Tuple, Dict
from collections import deque
import threading
import logging
from datetime import datetime

Gst.init(None)

# COCO class IDs for person and vehicles
COCO_PERSON = 0
COCO_VEHICLES = [2, 3, 5, 7]  # car, motorcycle, bus, truck

@dataclass
class ROI:
    """Region of Interest definition (relative coordinates 0.0-1.0)"""
    x1: float  # top-left x
    y1: float  # top-left y
    x2: float  # bottom-right x
    y2: float  # bottom-right y
    name: str = "default"
    
    def contains_bbox(self, bbox_x1, bbox_y1, bbox_x2, bbox_y2, 
                      frame_width, frame_height) -> bool:
        """
        Check if bbox overlaps with ROI (any overlap counts as detection in ROI).
        Returns True if there's ANY overlap between bbox and ROI.
        """
        # Convert ROI to absolute coordinates
        roi_abs_x1 = self.x1 * frame_width
        roi_abs_y1 = self.y1 * frame_height
        roi_abs_x2 = self.x2 * frame_width
        roi_abs_y2 = self.y2 * frame_height
        
        # Check for overlap (no overlap if completely separated)
        if (bbox_x2 < roi_abs_x1 or bbox_x1 > roi_abs_x2 or
            bbox_y2 < roi_abs_y1 or bbox_y1 > roi_abs_y2):
            return False
        return True

@dataclass
class DetectionStats:
    """Statistics for a single frame"""
    timestamp: float
    person_count: int
    vehicle_count: int
    total_detections: int
    processing_time_ms: float
    roi_name: str

class PerformanceMonitor:
    """Monitor pipeline performance"""
    def __init__(self, window_size=100):
        self.frame_times = deque(maxlen=window_size)
        self.detection_stats = deque(maxlen=window_size)
        self.lock = threading.Lock()
        
    def add_frame_time(self, time_ms: float):
        with self.lock:
            self.frame_times.append(time_ms)
    
    def add_detection(self, stats: DetectionStats):
        with self.lock:
            self.detection_stats.append(stats)
    
    def get_stats(self) -> Dict:
        with self.lock:
            if not self.frame_times:
                return {}
            
            avg_time = sum(self.frame_times) / len(self.frame_times)
            fps = 1000.0 / avg_time if avg_time > 0 else 0
            
            recent_persons = [s.person_count for s in list(self.detection_stats)[-10:]]
            recent_vehicles = [s.vehicle_count for s in list(self.detection_stats)[-10:]]
            
            return {
                'avg_processing_time_ms': round(avg_time, 2),
                'fps': round(fps, 2),
                'total_frames': len(self.frame_times),
                'recent_person_count': sum(recent_persons) / len(recent_persons) if recent_persons else 0,
                'recent_vehicle_count': sum(recent_vehicles) / len(recent_vehicles) if recent_vehicles else 0,
            }

class StatusHTTPServer(threading.Thread):
    """Simple HTTP server for headless monitoring"""
    def __init__(self, port, perf_monitor, config):
        super().__init__(daemon=True)
        self.port = port
        self.perf_monitor = perf_monitor
        self.config = config
        self.running = True
        
    def run(self):
        from http.server import HTTPServer, BaseHTTPRequestHandler
        
        class StatusHandler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass  # Suppress default logging
            
            def do_GET(s):
                if s.path == '/status':
                    stats = self.perf_monitor.get_stats()
                    response = {
                        'status': 'running',
                        'uptime': time.time() - start_time,
                        'config': {
                            'rtsp_url': self.config.get('rtsp_url', 'N/A'),
                            'roi': self.config.get('roi', {}),
                        },
                        'performance': stats,
                        'timestamp': datetime.now().isoformat(),
                    }
                    
                    s.send_response(200)
                    s.send_header('Content-type', 'application/json')
                    s.end_headers()
                    s.wfile.write(json.dumps(response, indent=2).encode())
                else:
                    s.send_response(404)
                    s.end_headers()
        
        global start_time
        start_time = time.time()
        
        server = HTTPServer(('0.0.0.0', self.port), StatusHandler)
        logging.info(f"Status server started on http://0.0.0.0:{self.port}/status")
        
        while self.running:
            server.handle_request()

class RTSPROICounter:
    def __init__(self, config_path: str):
        self.config = self.load_config(config_path)
        self.setup_logging()
        
        # Initialize components
        self.roi = ROI(**self.config['roi'])
        self.perf_monitor = PerformanceMonitor()
        self.pipeline = None
        self.loop = None
        self.frame_count = 0
        self.last_log_time = time.time()
        self.last_frame_time = None  # For measuring real frame-to-frame interval
        
        # Frame dimensions (will be updated from caps)
        self.frame_width = self.config.get('video_width', 640)
        self.frame_height = self.config.get('video_height', 640)
        
        # Start HTTP status server if enabled
        if self.config.get('enable_http_status', True):
            self.http_server = StatusHTTPServer(
                self.config.get('status_port', 8080),
                self.perf_monitor,
                self.config
            )
            self.http_server.start()
        
    def setup_logging(self):
        log_level = self.config.get('log_level', 'INFO')
        log_file = self.config.get('log_file', '/var/log/rtsp_roi_counter.log')
        
        # Try to create log directory, fall back to local if permission denied
        try:
            os.makedirs(os.path.dirname(log_file), exist_ok=True)
        except PermissionError:
            log_file = './rtsp_roi_counter.log'
            print(f"Warning: Cannot write to /var/log, using {log_file} instead")
        
        logging.basicConfig(
            level=getattr(logging, log_level),
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_file),
                logging.StreamHandler(sys.stdout)
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def load_config(self, config_path: str) -> Dict:
        """Load configuration from JSON file"""
        with open(config_path, 'r') as f:
            config = json.load(f)
        
        # Validate required fields
        required = ['rtsp_url', 'roi', 'hef_path', 'postprocess_so']
        for field in required:
            if field not in config:
                raise ValueError(f"Missing required config field: {field}")
        
        return config
    
    def find_postprocess_lib(self, custom_path: str = None) -> str:
        """Find the yolo postprocess library"""
        if custom_path and os.path.exists(custom_path):
            return custom_path
        
        possible_paths = [
            custom_path,
            "/usr/local/hailo/resources/so/libyolo_hailortpp_postprocess.so",
            "/usr/lib/aarch64-linux-gnu/hailo/tappas/post_processes/libyolo_hailortpp_postprocess.so",
        ]
        
        for path in possible_paths:
            if path and os.path.exists(path):
                self.logger.info(f"Found post-process library: {path}")
                return path
        
        raise FileNotFoundError("Post-process library not found")
    
    def on_buffer_probe(self, pad, info):
        """Process detection results using Hailo API"""
        current_time = time.time()
        
        # Calculate real frame interval (pipeline FPS)
        if self.last_frame_time is not None:
            frame_interval_ms = (current_time - self.last_frame_time) * 1000
        else:
            frame_interval_ms = 0
        self.last_frame_time = current_time
        
        buffer = info.get_buffer()
        if buffer is None:
            return Gst.PadProbeReturn.OK
        
        # Extract frame dimensions from caps on first frame if not set
        if self.frame_count == 0:
            caps = pad.get_current_caps()
            if caps and caps.get_size() > 0:
                structure = caps.get_structure(0)
                if structure.has_field('width') and structure.has_field('height'):
                    self.frame_width = structure.get_int('width')[1]
                    self.frame_height = structure.get_int('height')[1]
                    self.logger.info(f"Frame dimensions from pad caps: {self.frame_width}x{self.frame_height}")
        
        person_count = 0
        vehicle_count = 0
        total_detections = 0
        
        try:
            # Use Hailo API to get ROI from buffer
            import hailo
            
            # Get the root ROI from buffer
            roi = hailo.get_roi_from_buffer(buffer)
            
            # Get all detections from the ROI
            detections = roi.get_objects_typed(hailo.HAILO_DETECTION)
            
            if self.frame_count < 3:
                self.logger.info(f"Frame {self.frame_count}: Found {len(detections)} detections")
            
            # Label to COCO class ID mapping
            LABEL_TO_CLASS = {
                "person": 0,
                "car": 2,
                "automobile": 2,
                "motorcycle": 3,
                "motorbike": 3,
                "bus": 5,
                "truck": 7,
                "lorry": 7,
            }
            
            # Process each detection
            for detection in detections:
                # Try get_class_id first (more reliable), fall back to label
                class_id = None
                try:
                    if hasattr(detection, 'get_class_id'):
                        class_id = detection.get_class_id()
                except:
                    pass
                
                # If no class_id, try to get from label
                if class_id is None:
                    try:
                        label = detection.get_label()
                        if isinstance(label, str):
                            class_id = LABEL_TO_CLASS.get(label.lower())
                        elif isinstance(label, int):
                            class_id = label
                    except:
                        pass
                
                if class_id is None:
                    continue  # Skip if we can't determine class
                
                bbox = detection.get_bbox()
                confidence = detection.get_confidence()
                
                # Get bbox coordinates - Hailo returns normalized 0-1
                # We need to convert to absolute pixels for ROI comparison
                bbox_xmin = bbox.xmin()
                bbox_ymin = bbox.ymin()
                bbox_xmax = bbox.xmax()
                bbox_ymax = bbox.ymax()
                
                # Convert normalized coordinates to absolute pixels
                x1 = bbox_xmin * self.frame_width
                y1 = bbox_ymin * self.frame_height
                x2 = bbox_xmax * self.frame_width
                y2 = bbox_ymax * self.frame_height
                
                if self.frame_count < 3:
                    self.logger.debug(f"  Detection: class={class_id} (conf={confidence:.2f}) "
                                    f"norm=({bbox_xmin:.3f},{bbox_ymin:.3f},{bbox_xmax:.3f},{bbox_ymax:.3f}) "
                                    f"abs=({x1:.0f},{y1:.0f},{x2:.0f},{y2:.0f})")
                
                # Check if detection overlaps with ROI
                if self.roi.contains_bbox(x1, y1, x2, y2, self.frame_width, self.frame_height):
                    total_detections += 1
                    if class_id == COCO_PERSON:
                        person_count += 1
                        if self.frame_count < 3:
                            self.logger.info(f"  -> Person in ROI!")
                    elif class_id in COCO_VEHICLES:
                        vehicle_count += 1
                        if self.frame_count < 3:
                            self.logger.info(f"  -> Vehicle (class {class_id}) in ROI!")
        
        except ImportError as e:
            if self.frame_count == 0:
                self.logger.error(f"Cannot import hailo module: {e}")
                self.logger.error("Make sure Hailo environment is sourced: source setup_env.sh")
        except Exception as e:
            if self.frame_count < 5:
                self.logger.error(f"Error parsing detections: {e}")
                import traceback
                self.logger.error(traceback.format_exc())
        
        # Update statistics with REAL frame interval (skip first frame with interval=0)
        if frame_interval_ms > 0:
            stats = DetectionStats(
                timestamp=current_time,
                person_count=person_count,
                vehicle_count=vehicle_count,
                total_detections=total_detections,
                processing_time_ms=frame_interval_ms,  # Actually frame interval
                roi_name=self.roi.name
            )
            
            self.perf_monitor.add_frame_time(frame_interval_ms)
            self.perf_monitor.add_detection(stats)
        
        self.frame_count += 1
        
        # Periodic logging (less verbose now)
        if time.time() - self.last_log_time > self.config.get('log_interval', 10):
            perf_stats = self.perf_monitor.get_stats()
            self.logger.info(
                f"Frame {self.frame_count} | "
                f"Persons: {person_count} | Vehicles: {vehicle_count} | "
                f"Total detections in ROI: {total_detections} | "
                f"FPS: {perf_stats.get('fps', 0):.1f} | "
                f"Frame interval: {perf_stats.get('avg_processing_time_ms', 0):.1f}ms"
            )
            self.last_log_time = time.time()
        
        return Gst.PadProbeReturn.OK
    
    def on_message(self, bus, message):
        """Handle pipeline messages"""
        mtype = message.type
        
        if mtype == Gst.MessageType.EOS:
            self.logger.info("End of stream")
            self.loop.quit()
        elif mtype == Gst.MessageType.ERROR:
            err, debug = message.parse_error()
            self.logger.error(f"Pipeline error: {err}")
            self.logger.debug(f"Debug info: {debug}")
            self.loop.quit()
        elif mtype == Gst.MessageType.WARNING:
            warn, debug = message.parse_warning()
            self.logger.warning(f"Pipeline warning: {warn}")
        elif mtype == Gst.MessageType.STATE_CHANGED:
            if message.src == self.pipeline:
                old_state, new_state, pending = message.parse_state_changed()
                self.logger.debug(f"State changed: {old_state.value_nick} -> {new_state.value_nick}")
        
        return True
    
    def build_pipeline(self) -> str:
        """Build GStreamer pipeline string"""
        
        # RTSP source with buffering
        rtsp_url = self.config['rtsp_url']
        rtsp_latency = self.config.get('rtsp_latency', 200)
        
        source_pipeline = (
            f'rtspsrc location="{rtsp_url}" '
            f'latency={rtsp_latency} '
            'protocols=tcp ! '
            'queue max-size-buffers=3 leaky=downstream ! '
            'rtph264depay ! '
            'h264parse ! '
            'avdec_h264 threads=2 ! '
            'videoconvert ! '
        )
        
        # Resize for inference
        width = self.config.get('inference_width', 640)
        height = self.config.get('inference_height', 640)
        
        resize_pipeline = (
            'videoscale ! '
            f'video/x-raw,width={width},height={height},format=RGB,pixel-aspect-ratio=1/1 ! '
        )
        
        # Inference pipeline
        hef_path = self.config['hef_path']
        postprocess_so = self.find_postprocess_lib(self.config['postprocess_so'])
        batch_size = self.config.get('batch_size', 1)
        nms_score_threshold = self.config.get('nms_score_threshold', 0.3)
        nms_iou_threshold = self.config.get('nms_iou_threshold', 0.45)
        
        # Build NMS parameters string for hailonet (following Hailo's convention)
        nms_params = (
            f'nms-score-threshold={nms_score_threshold} '
            f'nms-iou-threshold={nms_iou_threshold} '
            f'output-format-type=HAILO_FORMAT_TYPE_FLOAT32'
        )
        
        inference_pipeline = (
            'queue max-size-buffers=3 max-size-bytes=0 max-size-time=0 ! '
            f'hailonet hef-path="{hef_path}" '
            f'batch-size={batch_size} '
            f'{nms_params} ! '
            
            'queue max-size-buffers=3 max-size-bytes=0 max-size-time=0 ! '
            f'hailofilter so-path={postprocess_so} '
            'qos=false name=hailo_filter ! '
            
            # hailooverlay processes the detections and makes them available
            'queue max-size-buffers=3 max-size-bytes=0 max-size-time=0 ! '
            'hailooverlay ! '
            'videoconvert ! '
        )
        
        # Sink - fakesink for headless operation
        sink_pipeline = 'fakesink sync=false'
        
        pipeline_str = source_pipeline + resize_pipeline + inference_pipeline + sink_pipeline
        
        self.logger.info("Pipeline built successfully")
        self.logger.debug(f"Pipeline: {pipeline_str}")
        
        return pipeline_str
    
    def run(self):
        """Run the detection pipeline"""
        self.logger.info("Starting RTSP ROI Counter")
        self.logger.info(f"RTSP URL: {self.config['rtsp_url']}")
        self.logger.info(f"ROI: {asdict(self.roi)}")
        self.logger.info(f"Target: Persons (class {COCO_PERSON}) and Vehicles (classes {COCO_VEHICLES})")
        
        # Build pipeline
        pipeline_str = self.build_pipeline()
        
        try:
            self.pipeline = Gst.parse_launch(pipeline_str)
        except GLib.Error as e:
            self.logger.error(f"Failed to create pipeline: {e}")
            return 1
        
        # Add probe to hailofilter output (before metadata might be lost)
        hailo_filter = self.pipeline.get_by_name('hailo_filter')
        if hailo_filter:
            src_pad = hailo_filter.get_static_pad('src')
            if src_pad:
                src_pad.add_probe(
                    Gst.PadProbeType.BUFFER,
                    self.on_buffer_probe
                )
                self.logger.info("Added buffer probe to hailofilter output")
                
                # Get actual frame dimensions from caps
                caps = src_pad.get_current_caps()
                if caps and caps.get_size() > 0:
                    structure = caps.get_structure(0)
                    if structure.has_field('width') and structure.has_field('height'):
                        self.frame_width = structure.get_int('width')[1]
                        self.frame_height = structure.get_int('height')[1]
                        self.logger.info(f"Frame dimensions from caps: {self.frame_width}x{self.frame_height}")
            else:
                self.logger.warning("Could not get src pad from hailo_filter")
        else:
            self.logger.warning("Could not find hailo_filter element")
        
        # Setup bus
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        self.loop = GLib.MainLoop()
        bus.connect("message", self.on_message)
        
        # Start pipeline
        ret = self.pipeline.set_state(Gst.State.PLAYING)
        if ret == Gst.StateChangeReturn.FAILURE:
            self.logger.error("Unable to set pipeline to PLAYING state")
            return 1
        
        self.logger.info("Pipeline started, processing RTSP stream...")
        
        # Run main loop
        try:
            self.loop.run()
        except KeyboardInterrupt:
            self.logger.info("Interrupted by user")
        finally:
            # Cleanup
            self.pipeline.set_state(Gst.State.NULL)
            self.logger.info("Pipeline stopped")
            
            # Print final statistics
            final_stats = self.perf_monitor.get_stats()
            self.logger.info(f"Final statistics: {json.dumps(final_stats, indent=2)}")
        
        return 0

def main():
    if len(sys.argv) < 2:
        print("Usage: rtsp_roi_counter.py <config.json>")
        print("\nExample config.json:")
        print(json.dumps({
            "rtsp_url": "rtsp://192.168.1.100:8554/stream",
            "hef_path": "/path/to/yolov6n.hef",
            "postprocess_so": "/path/to/libyolo_hailortpp_postprocess.so",
            "roi": {
                "x1": 0.2,
                "y1": 0.2,
                "x2": 0.8,
                "y2": 0.8,
                "name": "entrance"
            },
            "inference_width": 640,
            "inference_height": 640,
            "batch_size": 1,
            "nms_score_threshold": 0.3,
            "nms_iou_threshold": 0.45,
            "rtsp_latency": 200,
            "enable_http_status": True,
            "status_port": 8080,
            "log_file": "/var/log/rtsp_roi_counter.log",
            "log_level": "INFO",
            "log_interval": 10
        }, indent=2))
        return 1
    
    config_path = sys.argv[1]
    
    if not os.path.exists(config_path):
        print(f"Error: Config file not found: {config_path}")
        return 1
    
    app = RTSPROICounter(config_path)
    return app.run()

if __name__ == "__main__":
    sys.exit(main())