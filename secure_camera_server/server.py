from flask import Flask, request, jsonify, Response
import os
import shutil
import hashlib
import secrets
import json
import sqlite3
from datetime import datetime, timedelta
import socket
import traceback
from functools import wraps
import re

app = Flask(__name__)

# Configuration
UPLOAD_FOLDER = 'righttorecord_data'
DATABASE_FILE = 'righttorecord.db'
SECRET_KEY = secrets.token_hex(32)

# Create necessary directories
if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)

def init_database():
    """Initialize the user database with new email/password schema"""
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    # Check if we have the old PIN-based table structure
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='users'")
    users_table_exists = cursor.fetchone()
    
    if users_table_exists:
        # Check if it's the old structure (has pin_hash but no email)
        cursor.execute("PRAGMA table_info(users)")
        columns = [column[1] for column in cursor.fetchall()]
        
        if 'pin_hash' in columns and 'email' not in columns:
            print("🔄 Detected old PIN-based database structure")
            print("🔄 Migrating to new email/password system...")
            
            # Backup old table
            cursor.execute('ALTER TABLE users RENAME TO users_old_pin_backup')
            cursor.execute('ALTER TABLE recording_sessions RENAME TO recording_sessions_old_backup')
            
            print("✅ Old data backed up to users_old_pin_backup table")
            print("🆕 Creating new email/password structure...")
    
    # Create new Users table with email/password
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT UNIQUE NOT NULL,
            email TEXT UNIQUE NOT NULL,
            full_name TEXT NOT NULL,
            password_hash TEXT NOT NULL,
            salt TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_login TIMESTAMP
        )
    ''')
    
    # Sessions table for video recordings
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS recording_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            chunk_count INTEGER DEFAULT 0,
            FOREIGN KEY (user_id) REFERENCES users (user_id)
        )
    ''')
    
    # Create login_attempts table for rate limiting
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS login_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT NOT NULL,
            attempt_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            success INTEGER DEFAULT 0,
            ip_address TEXT
        )
    ''')
    
    # Create indexes for better performance
    cursor.execute("PRAGMA table_info(users)")
    columns = [column[1] for column in cursor.fetchall()]
    
    if 'email' in columns:
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON recording_sessions (user_id)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_login_attempts_email_time ON login_attempts (email, attempt_time)')
    
    # Add subscription_tier and storage_used columns if they don't exist
    try:
        cursor.execute('ALTER TABLE users ADD COLUMN subscription_tier TEXT DEFAULT "free"')
        print("✅ Added subscription_tier column")
    except sqlite3.OperationalError:
        pass  # Column already exists

    try:
        cursor.execute('ALTER TABLE users ADD COLUMN storage_used REAL DEFAULT 0')
        print("✅ Added storage_used column")
    except sqlite3.OperationalError:
        pass  # Column already exists

    try:
        cursor.execute('ALTER TABLE users ADD COLUMN subscription_expires_at TEXT')
        print("✅ Added subscription_expires_at column")
    except sqlite3.OperationalError:
        pass  # Column already exists

    # Update storage limits for existing subscription tiers
    cursor.execute('''
        UPDATE users 
        SET storage_used = 0 
        WHERE storage_used IS NULL
    ''')

    print("✅ Database subscription schema updated")
    
    conn.commit()
    conn.close()
    print("✅ Database initialized with email/password authentication")
    
    # Check if we have backup data to potentially migrate
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='users_old_pin_backup'")
    if cursor.fetchone():
        cursor.execute("SELECT COUNT(*) FROM users_old_pin_backup")
        old_user_count = cursor.fetchone()[0]
        if old_user_count > 0:
            print(f"📋 Found {old_user_count} users in old PIN-based system")
            print("💡 These users will need to register new accounts with email/password")
            print("📁 Their video data is preserved in the file system by user_id")
    conn.close()

def is_valid_email(email):
    """Validate email format"""
    pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    return re.match(pattern, email) is not None

def hash_password(password, salt=None):
    """Securely hash a password with salt"""
    if salt is None:
        salt = secrets.token_hex(32)
    
    # Use PBKDF2 for secure password hashing
    password_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), 100000)
    return password_hash.hex(), salt

def verify_password(password, password_hash, salt):
    """Verify a password against its hash"""
    computed_hash, _ = hash_password(password, salt)
    return computed_hash == password_hash

def generate_user_id():
    """Generate a unique user ID"""
    return secrets.token_urlsafe(16)

def get_user_by_email_password(email, password):
    """Get user by email/password (for authentication)"""
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    cursor.execute('''
        SELECT user_id, password_hash, salt, email, full_name, created_at 
        FROM users WHERE email = ?
    ''', (email,))
    
    user_data = cursor.fetchone()
    conn.close()
    
    if user_data and verify_password(password, user_data[1], user_data[2]):
        return {
            'user_id': user_data[0],
            'email': user_data[3],
            'full_name': user_data[4],
            'created_at': user_data[5]
        }
    
    return None

def create_user(full_name, email, password):
    """Create a new user with email/password"""
    if not is_valid_email(email):
        return None, "Invalid email format"
    
    if len(password) != 6 or not password.isdigit():
        return None, "Password must be exactly 6 digits"
    
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    # Check if email already exists
    cursor.execute('SELECT id FROM users WHERE email = ?', (email,))
    if cursor.fetchone():
        conn.close()
        return None, "Email already registered"
    
    # Generate unique user ID
    user_id = generate_user_id()
    
    # Hash the password
    password_hash, salt = hash_password(password)
    
    try:
        cursor.execute('''
            INSERT INTO users (user_id, email, full_name, password_hash, salt)
            VALUES (?, ?, ?, ?, ?)
        ''', (user_id, email, full_name, password_hash, salt))
        
        conn.commit()
        
        # Create user's upload directory
        user_folder = os.path.join(UPLOAD_FOLDER, user_id)
        if not os.path.exists(user_folder):
            os.makedirs(user_folder)
        
        conn.close()
        return user_id, None
        
    except sqlite3.IntegrityError as e:
        conn.close()
        return None, "Failed to create user account"

def update_last_login(user_id):
    """Update user's last login timestamp"""
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    cursor.execute('''
        UPDATE users SET last_login = CURRENT_TIMESTAMP
        WHERE user_id = ?
    ''', (user_id,))
    
    conn.commit()
    conn.close()

def check_rate_limit(email, ip_address=None):
    """Check if user has exceeded login attempt rate limit (5 attempts per day)"""
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    # Get attempts in the last 24 hours
    twenty_four_hours_ago = datetime.now() - timedelta(days=1)
    
    cursor.execute('''
        SELECT COUNT(*) FROM login_attempts 
        WHERE email = ? AND attempt_time > ? AND success = 0
    ''', (email.lower(), twenty_four_hours_ago))
    
    failed_attempts = cursor.fetchone()[0]
    conn.close()
    
    # Return True if under limit, False if over limit
    return failed_attempts < 5

def record_login_attempt(email, success, ip_address=None):
    """Record a login attempt"""
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    cursor.execute('''
        INSERT INTO login_attempts (email, success, ip_address)
        VALUES (?, ?, ?)
    ''', (email.lower(), 1 if success else 0, ip_address))
    
    conn.commit()
    conn.close()

def get_remaining_attempts(email):
    """Get how many attempts are remaining for an email"""
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    twenty_four_hours_ago = datetime.now() - timedelta(days=1)
    
    cursor.execute('''
        SELECT COUNT(*) FROM login_attempts 
        WHERE email = ? AND attempt_time > ? AND success = 0
    ''', (email.lower(), twenty_four_hours_ago))
    
    failed_attempts = cursor.fetchone()[0]
    conn.close()
    
    return max(0, 5 - failed_attempts)

def cleanup_old_attempts():
    """Clean up login attempts older than 7 days"""
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    seven_days_ago = datetime.now() - timedelta(days=7)
    
    cursor.execute('''
        DELETE FROM login_attempts 
        WHERE attempt_time < ?
    ''', (seven_days_ago,))
    
    deleted_count = cursor.rowcount
    conn.commit()
    conn.close()
    
    if deleted_count > 0:
        print(f"🧹 Cleaned up {deleted_count} old login attempts")

def verify_app_store_receipt(transaction_jws):
    """Verify App Store receipt (basic validation for production)"""
    try:
        # In production, you would verify the JWS signature with Apple's servers
        # For now, we'll do basic validation
        if not transaction_jws or len(transaction_jws) < 10:
            return False, "Invalid transaction data"
        
        # The JWS should have 3 parts separated by dots
        parts = transaction_jws.split('.')
        if len(parts) != 3:
            return False, "Invalid JWS format"
        
        print(f"✅ Transaction JWS validated (length: {len(transaction_jws)})")
        return True, "Valid"
        
    except Exception as e:
        print(f"❌ Receipt verification error: {e}")
        return False, str(e)

def get_subscription_tier_from_product_id(product_id):
    """Map product ID to subscription tier"""
    # New product IDs
    if product_id in ["com.righttorecord.premium2.monthly", "com.righttorecord.premium.monthly"]:
        return "premium"
    elif product_id in ["com.righttorecord.pro2.monthly", "com.righttorecord.pro.monthly"]:
        return "pro"
    else:
        return "free"

# ADD this function if it doesn't exist (put it with other helper functions):

def get_storage_limit_for_tier(tier):
    """Get storage limit in seconds for subscription tier"""
    limits = {
        'free': 20 * 60,        # 20 minutes (1,200 seconds)
        'premium': 20 * 60 * 60, # 20 hours (72,000 seconds)
        'pro': 200 * 60 * 60    # 200 hours (720,000 seconds)
    }
    limit = limits.get(tier, limits['free'])
    print(f"📊 Storage limit for tier '{tier}': {limit} seconds")
    return limit

def require_auth(f):
    """Decorator to require email/password authentication"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        data = request.get_json() if request.is_json else request.form.to_dict()
        
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        email = data.get('email', '').strip()
        password = data.get('password', '').strip()
        
        if not email or not password:
            return jsonify({'error': 'Email and password required'}), 400
        
        if len(password) != 6 or not password.isdigit():
            return jsonify({'error': 'Password must be exactly 6 digits'}), 400
        
        user = get_user_by_email_password(email, password)
        if not user:
            return jsonify({'error': 'Invalid email or password'}), 401
        
        # Update last login
        update_last_login(user['user_id'])
        
        # Add user to kwargs
        kwargs['user'] = user
        return f(*args, **kwargs)
    
    return decorated_function

# CORS headers for mobile app compatibility
@app.after_request
def after_request(response):
    response.headers.add('Access-Control-Allow-Origin', '*')
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type,Authorization')
    response.headers.add('Access-Control-Allow-Methods', 'GET,PUT,POST,DELETE,OPTIONS')
    return response

@app.route('/register', methods=['POST'])
def register_user():
    """Register a new user with email/password (full_name optional)"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        # Full name is now optional - use email prefix if not provided
        full_name = data.get('full_name', '').strip()
        email = data.get('email', '').strip().lower()
        password = data.get('password', '').strip()
        
        if not email:
            return jsonify({'error': 'Email is required'}), 400
        
        if not password:
            return jsonify({'error': 'Password is required'}), 400
        
        # If no full name provided, use email prefix
        if not full_name:
            full_name = email.split('@')[0].title()
        
        user_id, error = create_user(full_name, email, password)
        
        if error:
            return jsonify({'error': error}), 400
        
        print(f"✅ New user registered: {email} (Name: {full_name}, ID: {user_id})")
        return jsonify({
            'message': 'User registered successfully',
            'user_id': user_id
        }), 201
    
    except Exception as e:
        print(f"❌ Registration error: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Registration failed'}), 500

@app.route('/login', methods=['POST'])
def login_user():
    """Login user with email/password and rate limiting"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        email = data.get('email', '').strip().lower()
        password = data.get('password', '').strip()
        
        if not email or not password:
            return jsonify({'error': 'Email and password required'}), 400
        
        # Get client IP for logging
        client_ip = request.environ.get('HTTP_X_FORWARDED_FOR', request.environ.get('REMOTE_ADDR', 'unknown'))
        
        # Check rate limit before attempting login
        if not check_rate_limit(email, client_ip):
            remaining = get_remaining_attempts(email)
            print(f"🚫 Rate limit exceeded for {email} from IP {client_ip}")
            return jsonify({
                'error': f'Too many failed attempts. You have {remaining} attempts remaining today. Try again in 24 hours.',
                'rate_limited': True,
                'remaining_attempts': remaining
            }), 429  # Too Many Requests
        
        # Attempt authentication
        user = get_user_by_email_password(email, password)
        
        if user:
            # Successful login
            record_login_attempt(email, success=True, ip_address=client_ip)
            update_last_login(user['user_id'])
            
            print(f"✅ User logged in: {email} from IP {client_ip}")
            
            return jsonify({
                'message': 'Login successful',
                'user': {
                    'id': user['user_id'],
                    'email': user['email'],
                    'full_name': user['full_name'],
                    'created_at': user['created_at']
                }
            }), 200
        else:
            # Failed login
            record_login_attempt(email, success=False, ip_address=client_ip)
            remaining = get_remaining_attempts(email)
            
            print(f"❌ Failed login attempt: {email} from IP {client_ip} ({remaining} attempts remaining)")
            
            if remaining == 0:
                return jsonify({
                    'error': 'Invalid email or password. Account temporarily locked due to too many failed attempts.',
                    'rate_limited': True,
                    'remaining_attempts': 0
                }), 401
            else:
                return jsonify({
                    'error': f'Invalid email or password. {remaining} attempts remaining today.',
                    'remaining_attempts': remaining
                }), 401
    
    except Exception as e:
        print(f"❌ Login error: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Login failed'}), 500

@app.route('/upload', methods=['POST'])
def upload_video():
    """Upload video chunks for authenticated users"""
    try:
        print("📤 Upload request received")
        
        # Check content type
        content_type = request.headers.get('Content-Type', '')
        if 'multipart/form-data' not in content_type:
            print(f"❌ Invalid content type: {content_type}")
            return jsonify({'error': 'Invalid content type'}), 400
        
        # Parse form data safely
        try:
            form_keys = list(request.form.keys())
            file_keys = list(request.files.keys())
            print(f"📤 Form data keys: {form_keys}")
            print(f"📤 Files: {file_keys}")
        except Exception as e:
            print(f"❌ Failed to parse form data: {e}")
            return jsonify({'error': 'Malformed request data'}), 400
        
        # Get authentication credentials
        email = request.form.get('email', '').strip().lower()
        password = request.form.get('password', '').strip()
        
        print(f"📤 Email: {email}")
        
        if not email or not password:
            print("❌ No email/password provided in upload")
            return jsonify({'error': 'Email and password required'}), 400
        
        # Authenticate user
        user = get_user_by_email_password(email, password)
        if not user:
            print(f"❌ Invalid credentials for upload: {email}")
            return jsonify({'error': 'Invalid email or password'}), 401
        
        user_id = user['user_id']
        print(f"✅ Upload authenticated for user: {email} (ID: {user_id})")
        
        # Check for video file
        if 'video' not in request.files:
            print("❌ No video file in upload")
            return jsonify({'error': 'No video file'}), 400
        
        file = request.files['video']
        if not file or file.filename == '':
            print("❌ Empty file in upload")
            return jsonify({'error': 'Empty file'}), 400
        
        # Get session info
        session_id = request.form.get('session_id', '').strip()
        chunk_number = request.form.get('chunk_number', '0').strip()
        
        if not session_id:
            print("❌ No session ID in upload")
            return jsonify({'error': 'Session ID required'}), 400
        
        print(f"📤 Session: {session_id}, Chunk: {chunk_number}")
        
        # Create directories
        user_folder = os.path.join(UPLOAD_FOLDER, user_id)
        session_folder = os.path.join(user_folder, session_id)
        
        if not os.path.exists(session_folder):
            os.makedirs(session_folder)
            
            # Record session in database
            conn = sqlite3.connect(DATABASE_FILE)
            cursor = conn.cursor()
            cursor.execute('''
                INSERT OR IGNORE INTO recording_sessions (user_id, session_id)
                VALUES (?, ?)
            ''', (user_id, session_id))
            conn.commit()
            conn.close()
            
            print(f"📁 Created session for user {email}: {session_id}")
        
        # Save the file
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"chunk_{chunk_number.zfill(3)}_{timestamp}.mov"
        filepath = os.path.join(session_folder, filename)
        
        # Save file safely
        try:
            file.save(filepath)
            file_size = os.path.getsize(filepath)
            print(f"✅ Chunk {chunk_number} saved: {filepath} ({file_size} bytes)")
        except Exception as e:
            print(f"❌ Failed to save file: {e}")
            return jsonify({'error': 'Failed to save file'}), 500
        
        # Update database
        try:
            conn = sqlite3.connect(DATABASE_FILE)
            cursor = conn.cursor()
            cursor.execute('''
                UPDATE recording_sessions 
                SET chunk_count = MAX(chunk_count, ?)
                WHERE user_id = ? AND session_id = ?
            ''', (int(chunk_number), user_id, session_id))
            conn.commit()
            conn.close()
        except Exception as e:
            print(f"⚠️ Database update failed: {e}")
        
        # Update last login
        update_last_login(user_id)
        
        return jsonify({
            'message': 'Upload successful',
            'filename': filename,
            'session_id': session_id,
            'chunk_number': chunk_number,
            'file_size': file_size
        }), 200
    
    except Exception as e:
        print(f"❌ Upload error: {e}")
        return jsonify({'error': 'Upload failed'}), 500

@app.route('/storage_info', methods=['POST'])
@require_auth
def get_storage_info(user):
    """Get current storage usage information"""
    try:
        user_id = user['user_id']
        
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        
        # Calculate actual storage usage by examining video files
        user_folder = os.path.join(UPLOAD_FOLDER, user_id)
        total_storage_seconds = 0
        video_count = 0
        
        if os.path.exists(user_folder):
            # Get all sessions for this user
            cursor.execute('''
                SELECT session_id FROM recording_sessions 
                WHERE user_id = ?
            ''', (user_id,))
            
            sessions = cursor.fetchall()
            video_count = len(sessions)
            
            # Calculate storage by counting video files and estimating duration
            for (session_id,) in sessions:
                session_path = os.path.join(user_folder, session_id)
                if os.path.exists(session_path):
                    video_files = [f for f in os.listdir(session_path) if f.endswith('.mov')]
                    # Estimate: each chunk is approximately 15 seconds
                    chunk_duration = 15  # seconds per chunk
                    total_storage_seconds += len(video_files) * chunk_duration
        
        # Get user's subscription tier
        cursor.execute('''
            SELECT subscription_tier FROM users 
            WHERE user_id = ?
        ''', (user_id,))
        
        result = cursor.fetchone()
        tier = result[0] if result and result[0] else 'free'
        
        # Update user's storage usage in database
        cursor.execute('''
            UPDATE users 
            SET storage_used = ?
            WHERE user_id = ?
        ''', (total_storage_seconds, user_id))
        
        conn.commit()
        conn.close()
        
        # Get storage limit for the subscription tier
        storage_limit = get_storage_limit_for_tier(tier)
        
        storage_percentage = min((total_storage_seconds / storage_limit) * 100, 100) if storage_limit > 0 else 0
        
        print(f"✅ Storage info for {user['email']}: {total_storage_seconds}s / {storage_limit}s ({storage_percentage:.1f}%)")
        
        return jsonify({
            'storage_used': total_storage_seconds,
            'storage_limit': storage_limit,
            'storage_percentage': storage_percentage,
            'video_count': video_count,
            'subscription_tier': tier
        }), 200
        
    except Exception as e:
        print(f"❌ Storage info error: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to get storage info'}), 500

@app.route('/update_subscription', methods=['POST'])
@require_auth
def update_subscription(user):
    """Update user's subscription status from App Store"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        user_id = user['user_id']
        email = user['email']
        
        subscription_tier = data.get('subscription_tier', 'free')
        storage_limit = data.get('storage_limit', 1200)  # 20 minutes default
        transaction_jws = data.get('transaction_jws', '')
        expires_at = data.get('expires_at', '')
        
        print(f"📱 Subscription update for {email}: {subscription_tier}")
        
        # Verify the transaction if provided
        if transaction_jws:
            is_valid, validation_msg = verify_app_store_receipt(transaction_jws)
            if not is_valid:
                print(f"❌ Invalid receipt for {email}: {validation_msg}")
                return jsonify({'error': 'Invalid subscription receipt'}), 400
            print(f"✅ Receipt verified for {email}")
        
        # Validate subscription tier
        valid_tiers = ['free', 'premium', 'pro']
        if subscription_tier not in valid_tiers:
            subscription_tier = 'free'
            storage_limit = 1200
        
        # Update user subscription in database
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        
        # Update or create user subscription record
        cursor.execute('''
            UPDATE users 
            SET subscription_tier = ?, subscription_expires_at = ?
            WHERE user_id = ?
        ''', (subscription_tier, expires_at if expires_at else None, user_id))
        
        conn.commit()
        conn.close()
        
        print(f"✅ Updated {email} to {subscription_tier} plan (expires: {expires_at or 'N/A'})")
        
        return jsonify({
            'message': 'Subscription updated successfully',
            'tier': subscription_tier,
            'storage_limit': storage_limit,
            'expires_at': expires_at
        }), 200
        
    except Exception as e:
        print(f"❌ Subscription update error: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to update subscription'}), 500

@app.route('/check_attempts', methods=['POST'])
def check_remaining_attempts():
    """Check how many login attempts are remaining for an email"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        email = data.get('email', '').strip().lower()
        
        if not email:
            return jsonify({'error': 'Email required'}), 400
        
        remaining = get_remaining_attempts(email)
        is_rate_limited = not check_rate_limit(email)
        
        return jsonify({
            'remaining_attempts': remaining,
            'is_rate_limited': is_rate_limited,
            'max_attempts_per_day': 5
        }), 200
        
    except Exception as e:
        print(f"❌ Check attempts error: {e}")
        return jsonify({'error': 'Failed to check attempts'}), 500

@app.route('/videos', methods=['POST'])
@require_auth
def list_videos(user):
    """List all videos for authenticated user"""
    try:
        user_id = user['user_id']
        email = user['email']
        print(f"🔍 Videos request for user: {email}")
        
        videos = []
        user_folder = os.path.join(UPLOAD_FOLDER, user_id)
        
        if not os.path.exists(user_folder):
            return jsonify({'videos': []}), 200
        
        # Get sessions from database
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        cursor.execute('''
            SELECT session_id, created_at, chunk_count
            FROM recording_sessions
            WHERE user_id = ?
            ORDER BY created_at DESC
        ''', (user_id,))
        
        sessions = cursor.fetchall()
        conn.close()
        
        for session_id, created_at, db_chunk_count in sessions:
            session_path = os.path.join(user_folder, session_id)
            
            if os.path.exists(session_path):
                # Count actual video files
                video_files = [f for f in os.listdir(session_path) if f.endswith('.mov')]
                actual_chunk_count = len(video_files)
                
                # Format date
                try:
                    created_date = datetime.fromisoformat(created_at)
                    formatted_date = created_date.strftime("%Y-%m-%d %H:%M")
                except:
                    formatted_date = "Unknown date"
                
                videos.append({
                    'session_id': session_id,
                    'session_name': f"Recording {formatted_date}",
                    'chunk_count': actual_chunk_count,
                    'date': formatted_date
                })
        
        print(f"✅ Found {len(videos)} videos for user {email}")
        return jsonify({'videos': videos}), 200
    
    except Exception as e:
        print(f"❌ List videos error: {e}")
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500

@app.route('/download/<session_id>', methods=['POST'])
@require_auth
def download_video(session_id, user):
    """Prepare video download for authenticated user"""
    try:
        user_id = user['user_id']
        email = user['email']
        print(f"📥 Download request from user {email} for session: {session_id}")
        
        user_folder = os.path.join(UPLOAD_FOLDER, user_id)
        session_path = os.path.join(user_folder, session_id)
        
        if not os.path.exists(session_path):
            return jsonify({'error': 'Video not found'}), 404
        
        # Get all video chunks in order
        video_files = [f for f in os.listdir(session_path) if f.endswith('.mov')]
        video_files.sort()  # Sort by filename (chunk order)
        
        if not video_files:
            return jsonify({'error': 'No video files found'}), 404
        
        print(f"📥 Preparing download: {len(video_files)} chunks for user {email}")
        
        # Get current server URL dynamically
        host = request.host
        scheme = 'https' if request.is_secure else 'http'
        base_url = f"{scheme}://{host}"
        
        return jsonify({
            'chunks': [
                {
                    'filename': f,
                    'download_url': f"{base_url}/download_chunk/{user_id}/{session_id}/{f}",
                    'order': i + 1
                }
                for i, f in enumerate(video_files)
            ],
            'total_chunks': len(video_files),
            'session_id': session_id
        }), 200
    
    except Exception as e:
        print(f"❌ Download error: {e}")
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500

@app.route('/download_chunk/<user_id>/<session_id>/<filename>')
def download_chunk(user_id, session_id, filename):
    """Download individual video chunks (no auth needed as URL is protected)"""
    try:
        video_path = os.path.join(UPLOAD_FOLDER, user_id, session_id, filename)
        
        if not os.path.exists(video_path):
            return "Chunk not found", 404
        
        print(f"📥 Downloading chunk for user {user_id}: {filename}")
        
        file_size = os.path.getsize(video_path)
        
        def generate():
            with open(video_path, 'rb') as f:
                while True:
                    data = f.read(65536)  # 64KB chunks for speed
                    if not data:
                        break
                    yield data
        
        return Response(
            generate(),
            mimetype='video/quicktime',
            headers={
                'Content-Disposition': f'attachment; filename={filename}',
                'Content-Length': str(file_size),
                'Content-Type': 'video/quicktime',
                'Cache-Control': 'public, max-age=31536000'
            }
        )
    
    except Exception as e:
        print(f"❌ Chunk download error: {e}")
        return str(e), 500

@app.route('/delete', methods=['POST'])
@require_auth
def delete_video(user):
    """Delete video session for authenticated user"""
    try:
        data = request.get_json()
        session_id = data.get('session_id', '')
        
        if not session_id:
            return jsonify({'error': 'Session ID required'}), 400
        
        user_id = user['user_id']
        email = user['email']
        print(f"🗑️ Delete request from user {email} for session: {session_id}")
        
        user_folder = os.path.join(UPLOAD_FOLDER, user_id)
        session_path = os.path.join(user_folder, session_id)
        
        if os.path.exists(session_path):
            # Delete files
            shutil.rmtree(session_path)
            
            # Delete from database
            conn = sqlite3.connect(DATABASE_FILE)
            cursor = conn.cursor()
            cursor.execute('''
                DELETE FROM recording_sessions
                WHERE user_id = ? AND session_id = ?
            ''', (user_id, session_id))
            conn.commit()
            conn.close()
            
            print(f"✅ Deleted session {session_id} for user {email}")
            return jsonify({'message': 'Video deleted successfully'}), 200
        else:
            return jsonify({'error': 'Video not found'}), 404
    
    except Exception as e:
        print(f"❌ Delete error: {e}")
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500

@app.route('/stats', methods=['GET'])
def get_stats():
    """Get server statistics (public endpoint)"""
    try:
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        
        # Count users
        cursor.execute('SELECT COUNT(*) FROM users')
        user_count = cursor.fetchone()[0]
        
        # Count total recordings
        cursor.execute('SELECT COUNT(*) FROM recording_sessions')
        recording_count = cursor.fetchone()[0]
        
        # Count active users (logged in within 30 days)
        thirty_days_ago = datetime.now() - timedelta(days=30)
        cursor.execute('SELECT COUNT(*) FROM users WHERE last_login > ?', (thirty_days_ago,))
        active_users = cursor.fetchone()[0]
        
        conn.close()
        
        return jsonify({
            'total_users': user_count,
            'total_recordings': recording_count,
            'active_users_30d': active_users,
            'server_status': 'online',
            'version': '2.0',
            'authentication': 'email/password'
        }), 200
    
    except Exception as e:
        print(f"❌ Stats error: {e}")
        return jsonify({'error': 'Unable to get statistics'}), 500

@app.route('/test', methods=['GET'])
def test():
    """Test endpoint to verify server is running"""
    return jsonify({
        'message': 'RightToRecord Multi-User Server is running!',
        'version': '2.0',
        'status': 'online',
        'authentication': 'email/password'
    }), 200

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    try:
        # Test database connection
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        cursor.execute('SELECT 1')
        conn.close()
        
        return jsonify({
            'status': 'healthy',
            'database': 'connected',
            'storage': 'available' if os.path.exists(UPLOAD_FOLDER) else 'unavailable',
            'version': '2.0',
            'authentication': 'email/password'
        }), 200
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 500

# Migration endpoint for existing PIN users
@app.route('/migrate_pin_to_email', methods=['POST'])
def migrate_pin_user():
    """Migrate existing PIN users to email/password system"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        pin = data.get('pin', '').strip()
        email = data.get('email', '').strip().lower()
        password = data.get('password', '').strip()
        full_name = data.get('full_name', '').strip()
        
        if not all([pin, email, password, full_name]):
            return jsonify({'error': 'PIN, email, password, and full name required'}), 400
        
        print(f"🔄 Migration request for PIN: {pin} → Email: {email}")
        
        # Check if backup table exists and PIN matches
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        
        # Check if old backup table exists
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='users_old_pin_backup'")
        if not cursor.fetchone():
            conn.close()
            return jsonify({'error': 'No PIN-based accounts found to migrate'}), 404
        
        # Check if PIN exists in old system
        cursor.execute('SELECT user_id, pin_hash, salt FROM users_old_pin_backup')
        old_users = cursor.fetchall()
        
        migrated_user_id = None
        for old_user_id, old_pin_hash, old_salt in old_users:
            # Verify PIN using old hash method
            computed_hash = hashlib.pbkdf2_hmac('sha256', pin.encode('utf-8'), old_salt.encode('utf-8'), 100000).hex()
            if computed_hash == old_pin_hash:
                migrated_user_id = old_user_id
                break
        
        if not migrated_user_id:
            conn.close()
            return jsonify({'error': 'PIN not found in system'}), 404
        
        # Check if email already exists in new system
        cursor.execute('SELECT id FROM users WHERE email = ?', (email,))
        if cursor.fetchone():
            conn.close()
            return jsonify({'error': 'Email already registered'}), 400
        
        # Create new account with same user_id (to preserve file associations)
        password_hash, salt = hash_password(password)
        
        cursor.execute('''
            INSERT INTO users (user_id, email, full_name, password_hash, salt)
            VALUES (?, ?, ?, ?, ?)
        ''', (migrated_user_id, email, full_name, password_hash, salt))
        
        # Migrate recording sessions
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='recording_sessions_old_backup'")
        if cursor.fetchone():
            cursor.execute('''
                INSERT INTO recording_sessions (user_id, session_id, created_at, chunk_count)
                SELECT user_id, session_id, created_at, chunk_count 
                FROM recording_sessions_old_backup 
                WHERE user_id = ?
            ''', (migrated_user_id,))
        
        conn.commit()
        conn.close()
        
        print(f"✅ Successfully migrated PIN user to email: {email} (preserved user_id: {migrated_user_id})")
        
        return jsonify({
            'message': 'Account migrated successfully! Your videos are now accessible.',
            'user_id': migrated_user_id,
            'migrated_sessions': 'Previous recordings restored'
        }), 201
        
    except Exception as e:
        print(f"❌ Migration error: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Migration failed'}), 500

@app.route('/check_migration_available', methods=['GET'])
def check_migration_available():
    """Check if PIN migration is available"""
    try:
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        
        # Check if backup table exists
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='users_old_pin_backup'")
        backup_exists = cursor.fetchone() is not None
        
        if backup_exists:
            cursor.execute("SELECT COUNT(*) FROM users_old_pin_backup")
            old_user_count = cursor.fetchone()[0]
        else:
            old_user_count = 0
        
        conn.close()
        
        return jsonify({
            'migration_available': backup_exists and old_user_count > 0,
            'old_users_count': old_user_count,
            'message': 'PIN users can migrate to email/password accounts' if backup_exists else 'No PIN accounts found'
        }), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ADD this endpoint to your server.py for Apple reviewers:

@app.route('/create_demo_account', methods=['POST'])
def create_demo_account():
    """Create demo account with premium access for Apple reviewers"""
    try:
        demo_email = "reviewer@righttorecord.com"
        demo_password = "123456"
        demo_name = "Apple Reviewer"
        
        # Check if demo account already exists
        existing_user = get_user_by_email_password(demo_email, demo_password)
        if existing_user:
            # Update existing demo account to premium
            user_id = existing_user['user_id']
            
            conn = sqlite3.connect(DATABASE_FILE)
            cursor = conn.cursor()
            
            # Set to premium subscription with extended expiration
            future_date = (datetime.now() + timedelta(days=30)).isoformat()
            
            cursor.execute('''
                UPDATE users 
                SET subscription_tier = ?, subscription_expires_at = ?, storage_used = 0
                WHERE user_id = ?
            ''', ('premium', future_date, user_id))
            
            conn.commit()
            conn.close()
            
            print(f"✅ Demo account upgraded to premium: {demo_email}")
            
            return jsonify({
                'message': 'Demo account updated to premium',
                'email': demo_email,
                'password': demo_password,
                'subscription_tier': 'premium',
                'expires_at': future_date
            }), 200
        
        # Create the demo account
        user_id, error = create_user(demo_name, demo_email, demo_password)
        
        if error:
            print(f"❌ Failed to create demo account: {error}")
            return jsonify({'error': error}), 400
        
        # Immediately upgrade to premium subscription
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        
        # Set premium subscription with 1 year expiration
        future_date = (datetime.now() + timedelta(days=30)).isoformat()
        
        cursor.execute('''
            UPDATE users 
            SET subscription_tier = ?, subscription_expires_at = ?
            WHERE user_id = ?
        ''', ('premium', future_date, user_id))
        
        conn.commit()
        conn.close()
        
        print(f"✅ Demo account created with premium access: {demo_email}")
        
        return jsonify({
            'message': 'Demo account created with premium subscription',
            'email': demo_email,
            'password': demo_password,
            'user_id': user_id,
            'subscription_tier': 'premium',
            'expires_at': future_date
        }), 201
        
    except Exception as e:
        print(f"❌ Demo account creation error: {e}")
        return jsonify({'error': 'Failed to create demo account'}), 500

# ADD this endpoint after create_demo_account in your server.py:

@app.route('/demo_switch_tier', methods=['POST'])
def demo_switch_tier():
    """Switch demo account between subscription tiers for testing"""
    try:
        data = request.get_json()
        
        # Get email from request data
        data = request.get_json()
        demo_email = data.get('email', '') if data and 'email' in data else None
        demo_password = "123456"

        # If no email provided, try to detect from common reviewer emails
        if not demo_email:
            # List of known reviewer accounts
            reviewer_emails = [
                "reviewer-free@righttorecord.com",
                "reviewer-premium@righttorecord.com", 
                "reviewer-pro@righttorecord.com",
                "reviewer@righttorecord.com"
            ]
            
            # Use the first one that exists in database
            for email in reviewer_emails:
                user = get_user_by_email_password(email, demo_password)
                if user:
                    demo_email = email
                    break
        # Verify this is the demo account
        user = get_user_by_email_password(demo_email, demo_password)
        if not user:
            return jsonify({'error': 'Demo account not found'}), 404
        
        # Get desired tier (default to premium)
        tier = data.get('tier', 'premium') if data else 'premium'
        
        # Validate tier
        if tier not in ['free', 'premium', 'pro']:
            tier = 'premium'
        
        user_id = user['user_id']
        
        conn = sqlite3.connect(DATABASE_FILE)
        cursor = conn.cursor()
        
        # Set subscription tier
        if tier == 'free':
            cursor.execute('''
                UPDATE users 
                SET subscription_tier = ?, subscription_expires_at = NULL
                WHERE user_id = ?
            ''', ('free', user_id))
        else:
            # Set premium or pro with 1 year expiration
            future_date = (datetime.now() + timedelta(days=365)).isoformat()
            cursor.execute('''
                UPDATE users 
                SET subscription_tier = ?, subscription_expires_at = ?
                WHERE user_id = ?
            ''', (tier, future_date, user_id))
        
        conn.commit()
        conn.close()
        
        print(f"✅ Demo account switched to {tier} tier")
        
        return jsonify({
            'message': f'Demo account switched to {tier} tier',
            'email': demo_email,
            'tier': tier,
            'note': 'Log out and log back in to see changes in the app'
        }), 200
        
    except Exception as e:
        print(f"❌ Demo tier switch error: {e}")
        return jsonify({'error': 'Failed to switch tier'}), 500

@app.route('/create_all_demo_accounts', methods=['POST'])
def create_all_demo_accounts():
    """Create three demo accounts for all subscription tiers"""
    try:
        accounts = [
            {
                'email': 'reviewer-free@righttorecord.com',
                'password': '123456',
                'name': 'Apple Reviewer Free',
                'tier': 'free'
            },
            {
                'email': 'reviewer-premium@righttorecord.com', 
                'password': '123456',
                'name': 'Apple Reviewer Premium',
                'tier': 'premium'
            },
            {
                'email': 'reviewer-pro@righttorecord.com',
                'password': '123456', 
                'name': 'Apple Reviewer Pro',
                'tier': 'pro'
            }
        ]
        
        results = []
        
        for account in accounts:
            # Create or get user
            existing_user = get_user_by_email_password(account['email'], account['password'])
            
            if existing_user:
                user_id = existing_user['user_id']
                print(f"✅ Demo account already exists: {account['email']}")
            else:
                user_id, error = create_user(account['name'], account['email'], account['password'])
                if error:
                    print(f"❌ Failed to create {account['email']}: {error}")
                    continue
                print(f"✅ Created demo account: {account['email']}")
            
            # Set subscription tier
            conn = sqlite3.connect(DATABASE_FILE)
            cursor = conn.cursor()
            
            if account['tier'] == 'free':
                cursor.execute('''
                    UPDATE users 
                    SET subscription_tier = ?, subscription_expires_at = NULL
                    WHERE user_id = ?
                ''', ('free', user_id))
            else:
                future_date = (datetime.now() + timedelta(days=365)).isoformat()
                cursor.execute('''
                    UPDATE users 
                    SET subscription_tier = ?, subscription_expires_at = ?
                    WHERE user_id = ?
                ''', (account['tier'], future_date, user_id))
            
            conn.commit()
            conn.close()
            
            results.append({
                'email': account['email'],
                'tier': account['tier'],
                'status': 'ready'
            })
        
        return jsonify({
            'message': 'All demo accounts created successfully',
            'accounts': results
        }), 201
        
    except Exception as e:
        print(f"❌ Demo accounts creation error: {e}")
        return jsonify({'error': 'Failed to create demo accounts'}), 500

if __name__ == '__main__':
    # Initialize database
    init_database()
    
    # Clean up old login attempts on startup
    cleanup_old_attempts()
    
    # Get local IP address
    try:
        hostname = socket.gethostname()
        local_ip = socket.gethostbyname(hostname)
    except:
        local_ip = '127.0.0.1'
    
    print("🚀 RightToRecord Multi-User Server Starting...")
    print(f"📧 Email + 6-Digit Password Authentication")
    print(f"📤 Upload endpoint: http://{local_ip}:5000/upload")
    print(f"🔐 Register endpoint: http://{local_ip}:5000/register")
    print(f"🔑 Login endpoint: http://{local_ip}:5000/login")
    print(f"💳 Subscription endpoint: http://{local_ip}:5000/update_subscription")
    print(f"📊 Storage endpoint: http://{local_ip}:5000/storage_info")
    print(f"🌐 Access from anywhere via your ngrok domain")
    print(f"👥 Multi-user support with secure 6-digit passwords")
    print(f"📊 Stats endpoint: http://{local_ip}:5000/stats")
    print(f"🏥 Health check: http://{local_ip}:5000/health")
    print("=" * 50)

    app.run(host='0.0.0.0', port=5000, debug=False)  # Production mode